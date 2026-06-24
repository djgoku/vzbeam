# vzbeam Plan 3 — run lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `run` / `stop` / `kill` / `ssh` verbs plus a host-wide `run.lock` and the 2-VM cap to the vzbeam Elixir engine, built against an extended fake `vz` sidecar.

**Architecture:** Four new plumbing modules — `Shell`+`Daemon` (shell-quote + detached spawn), `Lock` (host-wide advisory lock via `:file.make_link/2`), `Keys` (baked ed25519 SSH keypair), `Share` (`--share` parse/validate) — plus a `Sidecar.stream/4` extension (Port-streamed `restore` + stderr tail) and four verb modules. The detach, lock, key generation, share validation, and the `run.log` startup handshake are all real and tested here; only the actual hypervisor boot is hardware-gated.

**Tech Stack:** Elixir `~> 1.17` (OTP 29), `escript`, `Jason` (the only dependency). macOS host.

## Global Constraints

- **No new dependencies** — Jason only; transport is zero-dep (`System.cmd`, `Port`, `sh -c`). erlexec/muontrap remain deferred.
- **`setsid(1)` and `flock(1)` do not exist on macOS** — detach via `nohup … >run.log 2>&1 & echo $!`; lock via `:file.make_link/2`. (Spec §2.)
- **All state writes atomic** — manifest / `vm.pid` via `VzBeam.AtomicFile`; the lock via temp+`make_link`.
- **Verb return contract:** `run/1 :: {:ok, iodata} | {:error, non_neg_integer, iodata}`; usage errors code `2`, runtime errors code `1`.
- **Testability:** external effects (spawn, lock, ssh, lease reads, signals) are injectable fns/maps with real defaults — mirror the existing `read_leases`/`runner` pattern. Tests are `async: false`, set `VZBEAM_HOME` to a unique tmp dir, and clean up in `on_exit`.
- **Green-bucket only:** no VM boot. The escript smoke-run (Task 9) exercises the real detach/handshake/kill against the fake; ExUnit cannot prove survival-after-BEAM-halt.
- **JSON maps are string-keyed** (Jason default); unknown keys preserved on read-modify-write.
- **`$VZBEAM_HOME`** default `~/.local/share/vzbeam`. Spec: `docs/superpowers/specs/2026-06-24-vzbeam-plan3-run-lifecycle.md`.

## File Structure

| File | Responsibility |
|---|---|
| `lib/vzbeam/shell.ex` (new) | POSIX single-quote escaping for `sh -c` strings |
| `lib/vzbeam/daemon.ex` (new) | Detached spawn (`nohup … & echo $!`), capture launch pid |
| `lib/vzbeam/lock.ex` (new) | Host-wide advisory lock (`make_link`, steal-confirmed-dead) |
| `lib/vzbeam/keys.ex` (new) | Baked ed25519 SSH keypair (lazy, idempotent) |
| `lib/vzbeam/share.ex` (new) | `--share tag=/path` parse + validate |
| `lib/vzbeam/sidecar.ex` (modify) | Add `stream/4`; reimplement `restore` over it |
| `lib/vzbeam/commands/run.ex` (new) | `run` verb: lock→cap→spawn→vm.pid→handshake |
| `lib/vzbeam/commands/stop.ex` (new) | `stop` verb: ssh `sudo -n shutdown` + reap |
| `lib/vzbeam/commands/kill.ex` (new) | `kill` verb: SIGTERM→SIGKILL + reap |
| `lib/vzbeam/commands/ssh.ex` (new) | `ssh` verb: one-shot + interactive (`Port :nouse_stdio`) |
| `lib/vzbeam/cli.ex` (modify) | Dispatch + `@usage` for the four verbs |
| `test/support/fake_vz` (modify) | `run` modes (started/started_exit/error/hang) + `restore` |

---

## Task 1: `VzBeam.Lock` — host-wide advisory lock

**Files:**
- Create: `lib/vzbeam/lock.ex`, `test/lock_test.exs`

**Interfaces:**
- Consumes: `VzBeam.Home.root/0`, `VzBeam.Pidfile.process_start/1` (`{:ok, String.t()} | :error`).
- Produces:
  - `acquire(timeout_ms :: pos_integer \\ 10_000) :: :ok | {:error, :lock_timeout | :lock_corrupt}`
  - `release() :: :ok`
  - `with_lock(fun :: (-> r), timeout_ms \\ 10_000) :: {:ok, r} | {:error, :lock_timeout | :lock_corrupt}`
  - `path() :: Path.t()` (`$VZBEAM_HOME/run.lock`)

- [ ] **Step 1: Write the failing tests**

```elixir
# test/lock_test.exs
defmodule VzBeam.LockTest do
  use ExUnit.Case, async: false
  alias VzBeam.Lock

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-lock-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    {:ok, home: home}
  end

  test "acquire creates a fresh $VZBEAM_HOME and locks, release removes it" do
    assert :ok = Lock.acquire(1_000)
    assert File.regular?(Lock.path())
    assert :ok = Lock.release()
    refute File.exists?(Lock.path())
  end

  test "serializes concurrent acquirers (mutual exclusion): 8 x 25 == 200" do
    counter = Path.join(System.get_env("VZBEAM_HOME"), "counter")
    File.mkdir_p!(Path.dirname(counter))
    File.write!(counter, "0")

    1..8
    |> Task.async_stream(
      fn _ ->
        Enum.each(1..25, fn _ ->
          {:ok, _} =
            Lock.with_lock(fn ->
              n = File.read!(counter) |> String.trim() |> String.to_integer()
              File.write!(counter, Integer.to_string(n + 1))
            end)
        end)
      end,
      max_concurrency: 8,
      timeout: 60_000
    )
    |> Stream.run()

    assert File.read!(counter) |> String.trim() == "200"
  end

  test "times out while a live holder keeps the lock" do
    :ok = Lock.acquire(1_000)
    assert {:error, :lock_timeout} = Lock.acquire(50)
    :ok = Lock.release()
  end

  test "steals a lock held by a confirmed-dead pid" do
    File.mkdir_p!(VzBeam.Home.root())
    File.write!(Lock.path(), Jason.encode!(%{"pid" => "999999", "startedAt" => "Sat Jan  1 00:00:00 2000"}))
    assert :ok = Lock.acquire(1_000)
    :ok = Lock.release()
  end

  test "unreadable lock content times out as :lock_corrupt" do
    File.mkdir_p!(VzBeam.Home.root())
    File.write!(Lock.path(), "not json")
    assert {:error, :lock_corrupt} = Lock.acquire(50)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/lock_test.exs`
Expected: FAIL — `VzBeam.Lock` undefined.

- [ ] **Step 3: Write the module**

```elixir
# lib/vzbeam/lock.ex
defmodule VzBeam.Lock do
  @moduledoc "Host-wide advisory lock at $VZBEAM_HOME/run.lock: atomic create-with-content via make_link, start-time-matched liveness, steal only a confirmed-dead holder."
  alias VzBeam.{Home, Pidfile}

  @poll_ms 5

  @spec path() :: Path.t()
  def path, do: Path.join(Home.root(), "run.lock")

  @spec with_lock((-> r), pos_integer) :: {:ok, r} | {:error, :lock_timeout | :lock_corrupt} when r: term
  def with_lock(fun, timeout_ms \\ 10_000) do
    case acquire(timeout_ms) do
      :ok ->
        try do
          {:ok, fun.()}
        after
          release()
        end

      {:error, _} = err ->
        err
    end
  end

  @spec acquire(pos_integer) :: :ok | {:error, :lock_timeout | :lock_corrupt}
  def acquire(timeout_ms \\ 10_000) do
    File.mkdir_p(Home.root())

    case Pidfile.process_start(System.pid()) do
      {:ok, started} ->
        record = Jason.encode!(%{"pid" => System.pid(), "startedAt" => started})
        deadline = System.monotonic_time(:millisecond) + timeout_ms
        loop(record, deadline)

      :error ->
        {:error, :lock_corrupt}
    end
  end

  @spec release() :: :ok
  def release do
    File.rm(path())
    :ok
  end

  defp loop(record, deadline) do
    tmp = "#{path()}.#{System.pid()}.#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, record)

    outcome =
      case :file.make_link(tmp, path()) do
        :ok -> :acquired
        {:error, :eexist} -> holder_status()
      end

    File.rm(tmp)

    case outcome do
      :acquired -> :ok
      :dead -> File.rm(path()); loop(record, deadline)
      status -> wait(record, deadline, reason(status))
    end
  end

  defp wait(record, deadline, reason) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, reason}
    else
      Process.sleep(@poll_ms)
      loop(record, deadline)
    end
  end

  defp reason(:corrupt), do: :lock_corrupt
  defp reason(_), do: :lock_timeout

  # :acquired | :dead (steal) | :alive (wait) | :corrupt (wait, distinct reason)
  defp holder_status do
    with {:ok, body} <- File.read(path()),
         {:ok, %{"pid" => pid, "startedAt" => started}} <- Jason.decode(body) do
      if Pidfile.process_start(pid) == {:ok, started}, do: :alive, else: :dead
    else
      {:error, :enoent} -> :dead
      _ -> :corrupt
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/lock_test.exs`
Expected: PASS (fresh-home acquire, 200/200 mutual exclusion, live-holder timeout, dead-pid steal, corrupt→timeout).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/lock.ex test/lock_test.exs
git commit -m "feat: VzBeam.Lock host-wide advisory lock (make_link, steal confirmed-dead)"
```

---

## Task 2: `VzBeam.Shell` + `VzBeam.Daemon` — detached spawn

**Files:**
- Create: `lib/vzbeam/shell.ex`, `lib/vzbeam/daemon.ex`, `test/shell_test.exs`, `test/daemon_test.exs`

**Interfaces:**
- Produces:
  - `VzBeam.Shell.quote_arg(term) :: String.t()` (POSIX single-quote escape), `VzBeam.Shell.join([term]) :: String.t()`
  - `VzBeam.Daemon.spawn_detached(argv :: [String.t()], log_path :: Path.t(), runner \\ &System.cmd/3) :: {:ok, pid :: pos_integer} | {:error, term}` — returns a **launch** pid (not startup success).

- [ ] **Step 1: Write the failing tests**

```elixir
# test/shell_test.exs
defmodule VzBeam.ShellTest do
  use ExUnit.Case, async: true

  test "single-quotes args and escapes embedded single quotes" do
    assert VzBeam.Shell.quote_arg("plain") == "'plain'"
    assert VzBeam.Shell.quote_arg("a b") == "'a b'"
    assert VzBeam.Shell.quote_arg("it's") == "'it'\\''s'"
    assert VzBeam.Shell.join(["a b", "c"]) == "'a b' 'c'"
  end
end
```

```elixir
# test/daemon_test.exs
defmodule VzBeam.DaemonTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "vzbeam-daemon-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "returns {:error, ...} when the spawn shell fails (injected runner)" do
    runner = fn "sh", ["-c", _cmd], _ -> {"boom", 1} end
    assert {:error, {:spawn_failed, 1, "boom"}} =
             VzBeam.Daemon.spawn_detached(["/bin/true"], "/tmp/x.log", runner)
  end

  test "spawns a detached child, redirects stdio to the log, returns a live reparented pid", %{dir: dir} do
    log = Path.join([dir, "sub dir", "run.log"])  # spaces in the path exercise quoting
    File.mkdir_p!(Path.dirname(log))

    assert {:ok, pid} =
             VzBeam.Daemon.spawn_detached(["/bin/sh", "-c", "echo hello; sleep 30"], log)

    assert is_integer(pid)
    Process.sleep(300)
    assert File.read!(log) =~ "hello"
    assert {_, 0} = System.cmd("ps", ["-p", Integer.to_string(pid)], stderr_to_stdout: true)
    {ppid, 0} = System.cmd("ps", ["-o", "ppid=", "-p", Integer.to_string(pid)])
    assert String.trim(ppid) == "1"  # reparented to launchd => survives BEAM exit
  after
    System.cmd("sh", ["-c", "pkill -f 'sleep 30' 2>/dev/null; true"])
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/shell_test.exs test/daemon_test.exs`
Expected: FAIL — modules undefined.

- [ ] **Step 3: Write the modules**

```elixir
# lib/vzbeam/shell.ex
defmodule VzBeam.Shell do
  @moduledoc "POSIX single-quote escaping for building `sh -c` command strings."

  @spec quote_arg(term) :: String.t()
  def quote_arg(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  @spec join([term]) :: String.t()
  def join(argv), do: Enum.map_join(argv, " ", &quote_arg/1)
end
```

```elixir
# lib/vzbeam/daemon.ex
defmodule VzBeam.Daemon do
  @moduledoc "Detached spawn: nohup the child, redirect stdio to a log, capture the launch pid. The child reparents to launchd and survives the BEAM exit; nohup makes it ignore SIGHUP."
  alias VzBeam.Shell

  @spec spawn_detached([String.t()], Path.t(), (String.t(), [String.t()], keyword -> {String.t(), non_neg_integer})) ::
          {:ok, pos_integer} | {:error, term}
  def spawn_detached(argv, log_path, runner \\ &System.cmd/3) do
    nohup = System.find_executable("nohup") || "/usr/bin/nohup"
    cmd = "#{Shell.quote_arg(nohup)} #{Shell.join(argv)} >#{Shell.quote_arg(log_path)} 2>&1 & echo $!"

    case runner.("sh", ["-c", cmd], []) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {pid, _} -> {:ok, pid}
          :error -> {:error, {:bad_pid, String.trim(out)}}
        end

      {out, status} ->
        {:error, {:spawn_failed, status, String.trim(out)}}
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/shell_test.exs test/daemon_test.exs`
Expected: PASS (quoting; spawn-failure; detached child alive + reparented + log written).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/shell.ex lib/vzbeam/daemon.ex test/shell_test.exs test/daemon_test.exs
git commit -m "feat: VzBeam.Shell quoting + VzBeam.Daemon detached spawn"
```

---

## Task 3: `VzBeam.Keys` — baked SSH keypair

**Files:**
- Create: `lib/vzbeam/keys.ex`, `test/keys_test.exs`

**Interfaces:**
- Consumes: `VzBeam.Home.root/0`.
- Produces: `ensure(runner \\ &System.cmd/3) :: {:ok, %{private: Path.t(), public: Path.t()}} | {:error, term}`; `private/0`, `public/0`, `dir/0`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/keys_test.exs
defmodule VzBeam.KeysTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-keys-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    :ok
  end

  test "generates an ed25519 keypair, idempotently" do
    assert {:ok, %{private: priv, public: pub}} = VzBeam.Keys.ensure()
    assert File.regular?(priv) and File.regular?(pub)
    assert File.read!(pub) =~ "ssh-ed25519"
    before = File.read!(priv)
    assert {:ok, _} = VzBeam.Keys.ensure()
    assert File.read!(priv) == before
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/keys_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write the module**

```elixir
# lib/vzbeam/keys.ex
defmodule VzBeam.Keys do
  @moduledoc "Baked SSH keypair at $VZBEAM_HOME/keys/id_ed25519[.pub], generated lazily on first need."
  alias VzBeam.Home

  @spec dir() :: Path.t()
  def dir, do: Path.join(Home.root(), "keys")

  @spec private() :: Path.t()
  def private, do: Path.join(dir(), "id_ed25519")

  @spec public() :: Path.t()
  def public, do: private() <> ".pub"

  @spec ensure((String.t(), [String.t()], keyword -> {String.t(), non_neg_integer})) ::
          {:ok, %{private: Path.t(), public: Path.t()}} | {:error, term}
  def ensure(runner \\ &System.cmd/3) do
    if File.regular?(private()) do
      {:ok, %{private: private(), public: public()}}
    else
      File.mkdir_p!(dir())

      case runner.("ssh-keygen", ["-t", "ed25519", "-N", "", "-C", "vzbeam", "-f", private()], stderr_to_stdout: true) do
        {_, 0} -> {:ok, %{private: private(), public: public()}}
        {out, _} -> {:error, {:keygen_failed, String.trim(out)}}
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/keys_test.exs`
Expected: PASS (real `ssh-keygen`; idempotent).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/keys.ex test/keys_test.exs
git commit -m "feat: VzBeam.Keys lazy ed25519 SSH keypair"
```

---

## Task 4: `VzBeam.Share` — `--share` parse/validate

**Files:**
- Create: `lib/vzbeam/share.ex`, `test/share_test.exs`

**Interfaces:**
- Produces: `parse(spec :: String.t()) :: {:ok, %{tag: String.t(), path: Path.t()}} | {:error, :no_equals | :empty_tag | :tag_too_long | :no_such_dir}`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/share_test.exs
defmodule VzBeam.ShareTest do
  use ExUnit.Case, async: true

  test "parses a valid tag=/path (first = splits; host dir must exist)" do
    dir = System.tmp_dir!()
    assert {:ok, %{tag: "shared", path: ^dir}} = VzBeam.Share.parse("shared=#{dir}")
  end

  test "rejects bad specs" do
    assert {:error, :no_equals}   = VzBeam.Share.parse("noequals")
    assert {:error, :empty_tag}   = VzBeam.Share.parse("=#{System.tmp_dir!()}")
    assert {:error, :tag_too_long} = VzBeam.Share.parse(String.duplicate("x", 37) <> "=#{System.tmp_dir!()}")
    assert {:error, :no_such_dir} = VzBeam.Share.parse("t=/no/such/dir/xyz")
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/share_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write the module**

```elixir
# lib/vzbeam/share.ex
defmodule VzBeam.Share do
  @moduledoc "Parse + validate a --share tag=/path argument (tag <=36 UTF-8 bytes, no '='; host dir must exist)."

  @max_tag 36

  @spec parse(String.t()) :: {:ok, %{tag: String.t(), path: Path.t()}} | {:error, atom}
  def parse(spec) do
    case String.split(spec, "=", parts: 2) do
      [_] ->
        {:error, :no_equals}

      [tag, path] ->
        abs = Path.expand(path)

        cond do
          tag == "" -> {:error, :empty_tag}
          byte_size(tag) > @max_tag -> {:error, :tag_too_long}
          not File.dir?(abs) -> {:error, :no_such_dir}
          true -> {:ok, %{tag: tag, path: abs}}
        end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/share_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/share.ex test/share_test.exs
git commit -m "feat: VzBeam.Share --share parse/validate"
```

---

## Task 5: `Sidecar.stream/4` — Port-streamed `restore` (+ stderr tail)

**Files:**
- Modify: `lib/vzbeam/sidecar.ex`, `test/sidecar_test.exs`, `test/support/fake_vz`

**Interfaces:**
- Consumes: `VzBeam.Protocol.decode_line/1`, `VzBeam.Shell`.
- Produces:
  - `stream(subcommand :: String.t(), args :: [String.t()], on_event :: (Protocol.event -> any) \\ fn _ -> :ok end) :: {:ok, [event]} | {:error, term}`
  - `restore(opts :: map, on_event \\ fn _ -> :ok end) :: {:ok, %{machine_identifier, hardware_model, mac_address, version, build}} | {:error, term}` (signature changes: 2nd arg is now an `on_event` callback, not a `runner`).

- [ ] **Step 1: Add `run` + `restore` modes to the fake sidecar**

```sh
# test/support/fake_vz  — REPLACE the whole script with:
#!/bin/sh
case "$1" in
  --version)   echo '{"type":"version","protocol":1}'; exit 0 ;;
  image-info)  echo '{"type":"image","version":"26.5.1","build":"25F80","url":"file:///x.ipsw","source":"latest"}'; exit 0 ;;
  reid)        echo '{"type":"reid","machineIdentifier":"NEW-ID","macAddress":"5e:11:22:33:44:55"}'; exit 0 ;;
  restore)
    echo '{"type":"progress","fraction":0.5}'
    echo '{"type":"restored","machineIdentifier":"RID","hardwareModel":"HW","macAddress":"5e:ab:cd:ef:00:11","version":"26.5.1","build":"25F80"}'
    exit 0 ;;
  run)
    # modes via env VZBEAM_FAKE_RUN: started (default) | started_exit | error | hang
    case "${VZBEAM_FAKE_RUN:-started}" in
      error)        echo '{"type":"error","domain":"VZErrorDomain","code":6,"message":"max VMs"}'; exit 6 ;;
      started_exit) echo "{\"type\":\"started\",\"pid\":$$}"; exit 0 ;;
      hang)         while true; do sleep 1; done ;;
      *)            trap 'echo "{\"type\":\"guest_stopped\"}"; exit 0' TERM
                    echo "{\"type\":\"started\",\"pid\":$$}"
                    while true; do sleep 1; done ;;
    esac ;;
  errorcase)   echo '{"type":"error","domain":"VZErrorDomain","code":6,"message":"max VMs"}'; exit 3 ;;
  *)           echo "fake_vz: unknown $1" 1>&2; exit 2 ;;
esac
```

- [ ] **Step 2: Write the failing tests**

```elixir
# test/sidecar_test.exs — add inside the module (keep existing tests + setup pointing VZBEAM_VZ at @fake)
  test "stream/4 yields progress events then the restored terminal (real Port + fake_vz)" do
    parent = self()

    assert {:ok, events} =
             Sidecar.stream(
               "restore",
               ~w(--ipsw x --disk d --aux a --disk-size 1 --cpu 1 --mem 1),
               fn ev -> send(parent, {:ev, ev}) end
             )

    assert Enum.any?(events, &match?({:event, "restored", _}, &1))
    assert_received {:ev, {:event, "progress", %{"fraction" => 0.5}}}
  end

  test "restore/1 returns the restored identity over the stream transport" do
    assert {:ok, %{machine_identifier: "RID", build: "25F80", version: "26.5.1"}} =
             Sidecar.restore(%{ipsw: "x", disk: "d", aux: "a", disk_size: 1, cpu: 1, mem: 1})
  end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `chmod +x test/support/fake_vz && mix test test/sidecar_test.exs`
Expected: FAIL — `Sidecar.stream/4` undefined (and `restore/1` now routes through it).

- [ ] **Step 4: Add `stream/4`, reimplement `restore`, factor the precedence resolver**

```elixir
# lib/vzbeam/sidecar.ex — add `alias VzBeam.Shell` to the existing alias line, add @line_max, and the functions below.
# Replace the existing restore/2 with the version here. Keep call/3, check_version, image_info, reid, locate, find.

  @line_max 1_048_576

  @spec stream(String.t(), [String.t()], (Protocol.event() -> any)) :: {:ok, [Protocol.event()]} | {:error, term}
  def stream(subcommand, args, on_event \\ fn _ -> :ok end) do
    with {:ok, path} <- locate() do
      stderr = Path.join(System.tmp_dir!(), "vz-stderr-#{System.unique_integer([:positive])}")
      cmd = "#{Shell.join([path, subcommand | args])} 2>#{Shell.quote_arg(stderr)}"
      port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, {:line, @line_max}, args: ["-c", cmd]])

      {events, status} = collect_stream(port, on_event, [])
      tail = stderr_tail(stderr)
      File.rm(stderr)
      resolve(events, subcommand, status, tail)
    end
  end

  @spec restore(map, (Protocol.event() -> any)) :: {:ok, map} | {:error, term}
  def restore(opts, on_event \\ fn _ -> :ok end) do
    args = ["--ipsw", opts.ipsw, "--disk", opts.disk, "--aux", opts.aux,
            "--disk-size", to_string(opts.disk_size),
            "--cpu", to_string(opts.cpu), "--mem", to_string(opts.mem)]

    with {:ok, events} <- stream("restore", args, on_event),
         {:event, "restored", m} <- find(events, "restored") do
      {:ok, %{machine_identifier: m["machineIdentifier"], hardware_model: m["hardwareModel"],
              mac_address: m["macAddress"], version: m["version"], build: m["build"]}}
    end
  end

  defp collect_stream(port, on_event, acc) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Protocol.decode_line(line) do
          {:event, _, _} = ev -> on_event.(ev); collect_stream(port, on_event, [ev | acc])
          {:error, _} -> collect_stream(port, on_event, acc)
        end

      {^port, {:data, {:noeol, _partial}}} ->
        collect_stream(port, on_event, acc)

      {^port, {:exit_status, status}} ->
        {Enum.reverse(acc), status}
    end
  end

  defp resolve(events, subcommand, status, stderr_tail) do
    error = Enum.find(events, &match?({:event, "error", _}, &1))
    terminal = Enum.find(events, fn {:event, t, _} -> t in Map.get(@terminals, subcommand, []) end)

    cond do
      error ->
        {:event, "error", m} = error
        {:error, {:vz, m["domain"], m["code"], m["message"]}}

      status != 0 ->
        {:error, {:exit, status, stderr_tail}}

      terminal ->
        {:ok, events}

      true ->
        {:error, :no_terminal}
    end
  end

  defp stderr_tail(path) do
    case File.read(path) do
      {:ok, body} -> body |> String.slice(-4096, 4096) |> to_string()
      _ -> ""
    end
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/sidecar_test.exs`
Expected: PASS (stream progress+restored; `restore/1` via the stream). Then `mix test` — confirm `new_test.exs` is still green (it injects `restore`, so the signature change is transparent).

- [ ] **Step 6: Commit**

```bash
chmod +x test/support/fake_vz
git add lib/vzbeam/sidecar.ex test/sidecar_test.exs test/support/fake_vz
git commit -m "feat: Sidecar.stream/4 Port-streamed restore + stderr tail; fake_vz run/restore modes"
```

---

## Task 6: `VzBeam.Commands.Run` — the run lifecycle (+ CLI)

**Files:**
- Create: `lib/vzbeam/commands/run.ex`, `test/commands/run_test.exs`
- Modify: `lib/vzbeam/cli.ex`

**Interfaces:**
- Consumes: `Lock.with_lock/1`, `Daemon.spawn_detached/2`, `Keys.ensure/0`, `Share.parse/1`, `Sidecar.locate/0` + `check_version/0`, `Manifest.read/1`, `Home.{bundle_dir/1, bundles/0}`, `Pidfile.{write/2, running?/1, path/1}`, `Defaults.resolve/2`, `Protocol.decode_line/1`.
- Produces:
  - `run(args, deps \\ default_deps()) :: {:ok, iodata} | {:error, code, iodata}`; `deps = %{with_lock: (fun -> {:ok,_}|{:error,_}), spawn: (argv, log -> {:ok,pid}|{:error,_})}`.
  - `count_running() :: non_neg_integer`
  - `await_started(run_log :: Path.t(), pid :: pos_integer, timeout_ms :: pos_integer) :: {:ok, pos_integer} | {:error, {:vz, term, term, term} | :exited_early | :timeout}`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/commands/run_test.exs
defmodule VzBeam.Commands.RunTest do
  use ExUnit.Case, async: false
  alias VzBeam.Commands.Run

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-run-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    System.put_env("VZBEAM_VZ", Path.expand("../support/fake_vz", __DIR__))
    File.chmod!(Path.expand("../support/fake_vz", __DIR__), 0o755)
    make_bundle("dev")
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); System.delete_env("VZBEAM_VZ"); File.rm_rf!(home) end)
    {:ok, home: home}
  end

  defp make_bundle(name) do
    dir = Path.join(System.get_env("VZBEAM_HOME"), name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "config.json"),
      Jason.encode!(%{"name" => name, "macAddress" => "5e:aa:bb:cc:dd:ee",
                      "cpuCount" => 2, "memoryBytes" => 2_147_483_648}))
  end

  # with_lock that just runs the fun (no real locking); spawn returns a chosen result.
  defp deps(spawn_fn), do: %{with_lock: fn fun -> {:ok, fun.()} end, spawn: spawn_fn}

  test "usage error without a name" do
    assert {:error, 2, _} = Run.run([], deps(fn _, _ -> {:ok, 1} end))
  end

  test "refuses a missing bundle" do
    assert {:error, 1, msg} = Run.run(["ghost"], deps(fn _, _ -> {:ok, 1} end))
    assert IO.iodata_to_binary(msg) =~ "no such bundle"
  end

  test "refuses at the 2-VM cap (real count_running over two live pidfiles)" do
    for n <- ["a", "b"] do
      make_bundle(n)
      :ok = VzBeam.Pidfile.write(n, System.pid())  # System.pid() is alive => counts as running
    end

    assert {:error, 1, msg} = Run.run(["dev"], deps(fn _, _ -> flunk("must not spawn at cap") end))
    assert IO.iodata_to_binary(msg) =~ "capacity"
  end

  test "spawn forked but vz exited fast -> :process_not_found path -> typed error, no stale vm.pid" do
    # spawn returns a pid that is already dead, and we pre-seed run.log with an error event.
    File.write!(Path.join([System.get_env("VZBEAM_HOME"), "dev", "run.log"]),
      ~s({"type":"error","domain":"VZErrorDomain","code":6,"message":"max VMs"}\n))

    assert {:error, 1, msg} = Run.run(["dev"], deps(fn _argv, _log -> {:ok, 999_999} end))
    assert IO.iodata_to_binary(msg) =~ "VZError 6"
    refute File.exists?(VzBeam.Pidfile.path("dev"))
  end

  test "happy path: started + live pid -> success, vm.pid written" do
    # spawn a real, live child and pre-seed run.log with a 'started' line.
    {out, 0} = System.cmd("sh", ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"])
    pid = out |> String.trim() |> String.to_integer()
    on_exit(fn -> System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true) end)
    File.write!(Path.join([System.get_env("VZBEAM_HOME"), "dev", "run.log"]),
      ~s({"type":"started","pid":#{pid}}\n))

    assert {:ok, msg} = Run.run(["dev"], deps(fn _argv, _log -> {:ok, pid} end))
    assert IO.iodata_to_binary(msg) =~ "started dev"
    assert {:ok, %{"pid" => ^pid}} = VzBeam.Pidfile.read("dev")
  end

  test "await_started: started+alive -> ok; started+dead -> exited_early; error -> vz; timeout" do
    log = Path.join([System.get_env("VZBEAM_HOME"), "dev", "hs.log"])
    File.mkdir_p!(Path.dirname(log))

    me = System.pid() |> String.to_integer()  # the BEAM is always alive
    File.write!(log, ~s({"type":"started","pid":#{me}}\n))
    assert {:ok, ^me} = Run.await_started(log, me, 1_000)

    File.write!(log, ~s({"type":"started","pid":999999}\n))
    assert {:error, :exited_early} = Run.await_started(log, 999_999, 1_000)

    File.write!(log, ~s({"type":"error","domain":"D","code":6,"message":"m"}\n))
    assert {:error, {:vz, "D", 6, "m"}} = Run.await_started(log, me, 1_000)

    File.write!(log, "")  # no started, BEAM alive -> times out
    assert {:error, :timeout} = Run.await_started(log, me, 30)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/commands/run_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write the verb + wire the CLI**

```elixir
# lib/vzbeam/commands/run.ex
defmodule VzBeam.Commands.Run do
  @moduledoc "run <name> [--gui|--headless] [--resolution WxH] [--share tag=/path] — boot a VM (detached)."
  alias VzBeam.{Home, Manifest, Pidfile, Defaults, Keys, Share, Sidecar, Daemon, Lock, Protocol}

  @handshake_ms 60_000
  @poll_ms 100

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, default_deps())

  def run(args, deps) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [gui: :boolean, headless: :boolean, resolution: :string, share: :string])

    case positional do
      [name] -> start(name, opts, deps)
      _ -> {:error, 2, "usage: vzbeam run <name> [--gui|--headless] [--resolution WxH] [--share tag=/path]\n"}
    end
  end

  defp start(name, opts, deps) do
    with {:ok, m} <- read_manifest(name),
         :ok <- refute_running(name),
         {:ok, share} <- parse_share(opts[:share]),
         {:ok, _keys} <- Keys.ensure(),
         {:ok, vz} <- Sidecar.locate(),
         :ok <- Sidecar.check_version() do
      run_log = Path.join(Home.bundle_dir(name), "run.log")
      argv = build_argv(vz, name, m, opts, share)

      case launch(name, argv, run_log, deps) do
        {:ok, pid} -> finish(name, pid, run_log)
        {:spawn_exited, pid} -> classify_failure(name, pid, run_log)
        {:error, reason} -> error(reason)
      end
    else
      err -> error(err)
    end
  end

  defp launch(name, argv, run_log, deps) do
    File.mkdir_p!(Home.bundle_dir(name))

    result =
      deps.with_lock.(fn ->
        if count_running() >= 2 do
          {:error, :at_capacity}
        else
          case deps.spawn.(argv, run_log) do
            {:ok, pid} ->
              case Pidfile.write(name, pid) do
                :ok -> {:ok, pid}
                {:error, :process_not_found} -> {:spawn_exited, pid}
              end

            {:error, _} = err ->
              err
          end
        end
      end)

    case result do
      {:ok, inner} -> inner
      {:error, lock_err} -> {:error, lock_err}
    end
  end

  @spec count_running() :: non_neg_integer
  def count_running, do: Enum.count(Home.bundles(), &Pidfile.running?/1)

  defp finish(name, pid, run_log) do
    case await_started(run_log, pid, @handshake_ms) do
      {:ok, _} ->
        {:ok, ["started ", name, " (pid ", Integer.to_string(pid),
               ") — networking; try `vzbeam ip ", name, "` or `vzbeam ssh ", name, "`\n"]}

      {:error, _reason} = err ->
        cleanup(name, pid)
        started_error(err, run_log)
    end
  end

  @spec await_started(Path.t(), pos_integer, pos_integer) :: {:ok, pos_integer} | {:error, term}
  def await_started(run_log, pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(run_log, pid, deadline)
  end

  defp poll(run_log, pid, deadline) do
    events = read_events(run_log)
    error = Enum.find(events, &match?({:event, "error", _}, &1))

    cond do
      error ->
        {:event, "error", m} = error
        {:error, {:vz, m["domain"], m["code"], m["message"]}}

      Enum.any?(events, &match?({:event, "guest_stopped", _}, &1)) ->
        {:error, :exited_early}

      started?(events) and alive?(pid) ->
        {:ok, pid}

      started?(events) or not alive?(pid) ->
        {:error, :exited_early}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(@poll_ms)
        poll(run_log, pid, deadline)
    end
  end

  defp read_events(run_log) do
    body = case File.read(run_log) do
      {:ok, b} -> b
      _ -> ""
    end

    lines = String.split(body, "\n")
    complete = if body == "" or String.ends_with?(body, "\n"), do: lines, else: Enum.drop(lines, -1)

    complete
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Protocol.decode_line/1)
    |> Enum.filter(&match?({:event, _, _}, &1))
  end

  defp started?(events), do: Enum.any?(events, &match?({:event, "started", _}, &1))

  defp alive?(pid), do: match?({_, 0}, System.cmd("ps", ["-p", Integer.to_string(pid)], stderr_to_stdout: true))

  defp classify_failure(name, pid, run_log) do
    cleanup(name, pid)
    events = read_events(run_log)

    case Enum.find(events, &match?({:event, "error", _}, &1)) do
      {:event, "error", m} ->
        {:error, 1, ["run failed: VZError ", to_string(m["code"]), " ", to_string(m["message"]), "\n"]}

      _ ->
        {:error, 1, ["run failed: sidecar exited during startup; see ", run_log, "\n"]}
    end
  end

  defp cleanup(name, pid) do
    if alive?(pid), do: System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    File.rm(Pidfile.path(name))
  end

  defp build_argv(vz, name, m, opts, share) do
    [vz, "run", "--bundle", Home.bundle_dir(name), "--mac", m["macAddress"],
     "--cpu", to_string(m["cpuCount"]), "--mem", to_string(m["memoryBytes"]),
     mode_flag(opts), "--resolution", Defaults.resolve(opts[:resolution], :resolution)] ++ share_args(share)
  end

  defp mode_flag(opts), do: if(opts[:gui], do: "--gui", else: "--headless")
  defp share_args(nil), do: []
  defp share_args(%{tag: t, path: p}), do: ["--share", t, p]

  defp read_manifest(name) do
    case Manifest.read(name) do
      {:ok, m} -> {:ok, m}
      _ -> {:error, :no_such_bundle}
    end
  end

  defp refute_running(name), do: if(Pidfile.running?(name), do: {:error, :already_running}, else: :ok)
  defp parse_share(nil), do: {:ok, nil}
  defp parse_share(spec), do: Share.parse(spec)

  defp started_error({:error, {:vz, _d, code, msg}}, _log),
    do: {:error, 1, ["run failed: VZError ", to_string(code), " ", to_string(msg), "\n"]}

  defp started_error({:error, :timeout}, log),
    do: {:error, 1, ["run timed out waiting for startup; see ", log, "\n"]}

  defp started_error({:error, :exited_early}, log),
    do: {:error, 1, ["run failed: VM exited during startup; see ", log, "\n"]}

  defp error({:error, :no_such_bundle}), do: {:error, 1, "run: no such bundle\n"}
  defp error({:error, :already_running}), do: {:error, 1, "run: already running\n"}
  defp error({:error, :at_capacity}), do: {:error, 1, "run: at capacity (2 VMs already running); stop one first\n"}
  defp error({:error, :lock_timeout}), do: {:error, 1, ["run: another `vzbeam run` is in progress; retry\n"]}
  defp error({:error, :lock_corrupt}), do: {:error, 1, ["run: ", VzBeam.Lock.path(), " is unreadable; remove it if stale\n"]}
  defp error({:error, :not_found}), do: {:error, 1, "run: sidecar not found; build it (`vzbeam build-sidecar`)\n"}
  defp error({:error, :no_equals}), do: {:error, 2, "run: --share must be tag=/path\n"}
  defp error({:error, :empty_tag}), do: {:error, 2, "run: --share tag is empty\n"}
  defp error({:error, :tag_too_long}), do: {:error, 2, "run: --share tag exceeds 36 bytes\n"}
  defp error({:error, :no_such_dir}), do: {:error, 2, "run: --share host dir does not exist\n"}
  defp error({:error, reason}), do: {:error, 1, ["run failed: ", inspect(reason), "\n"]}

  defp default_deps, do: %{with_lock: &Lock.with_lock/1, spawn: &Daemon.spawn_detached/2}
end
```

```elixir
# lib/vzbeam/cli.ex — add a clause (before the catch-all)
  def run(["run" | rest]), do: VzBeam.Commands.Run.run(rest)
```
```
    run <name> [--gui|--headless] [--resolution WxH] [--share tag=/path]  boot a VM (detached)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/commands/run_test.exs test/cli_test.exs`
Expected: PASS (usage, missing bundle, cap refusal, spawn-exited error, happy path, handshake outcomes).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/commands/run.ex test/commands/run_test.exs lib/vzbeam/cli.ex
git commit -m "feat: run verb (lock + 2-VM cap + detached spawn + run.log handshake)"
```

---

## Task 7: `VzBeam.Commands.Stop` — graceful shutdown (+ CLI)

**Files:**
- Create: `lib/vzbeam/commands/stop.ex`, `test/commands/stop_test.exs`
- Modify: `lib/vzbeam/cli.ex`

**Interfaces:**
- Consumes: `Manifest.read/1`, `Pidfile.{running?/1, path/1}`, `Keys.ensure/0` + `Keys.private/0`, `Leases.{read/0, lookup_ip/2}`, `Defaults.values/0`.
- Produces: `run(args, deps \\ default_deps()) :: {:ok, iodata} | {:error, code, iodata}`; `deps = %{ssh: ([String.t()] -> {String.t(), non_neg_integer}), leases: (-> String.t()), reap_ms: pos_integer}`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/commands/stop_test.exs
defmodule VzBeam.Commands.StopTest do
  use ExUnit.Case, async: false
  alias VzBeam.Commands.Stop

  @mac "5e:aa:bb:cc:dd:ee"

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-stop-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    dir = Path.join(home, "dev")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "config.json"), Jason.encode!(%{"name" => "dev", "macAddress" => @mac}))
    :ok = VzBeam.Pidfile.write("dev", System.pid())  # running
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    {:ok, home: home}
  end

  defp leases, do: "{\n\tname=dev\n\tip_address=192.168.64.7\n\thw_address=1,#{@mac}\n}\n"

  test "issues a key-based, BatchMode, sudo -n shutdown and reaps on pid disappearance" do
    parent = self()

    ssh = fn args ->
      send(parent, {:ssh, args})
      File.rm(VzBeam.Pidfile.path("dev"))  # simulate guest shutdown -> process gone
      {"", 0}
    end

    assert {:ok, msg} = Stop.run(["dev"], %{ssh: ssh, leases: fn -> leases() end, reap_ms: 5_000})
    assert IO.iodata_to_binary(msg) =~ "stopped dev"
    assert_received {:ssh, args}
    joined = Enum.join(args, " ")
    assert joined =~ "BatchMode=yes" and joined =~ "sudo -n shutdown -h now" and joined =~ "admin@192.168.64.7"
    refute File.exists?(VzBeam.Pidfile.path("dev"))
  end

  test "times out when the VM does not stop" do
    ssh = fn _ -> {"", 0} end  # does nothing; pid stays alive
    assert {:error, 1, msg} = Stop.run(["dev"], %{ssh: ssh, leases: fn -> leases() end, reap_ms: 0})
    assert IO.iodata_to_binary(msg) =~ "kill"
  end

  test "refuses a stopped VM and a missing lease" do
    File.rm(VzBeam.Pidfile.path("dev"))
    assert {:error, 1, m1} = Stop.run(["dev"], %{ssh: fn _ -> {"", 0} end, leases: fn -> "" end, reap_ms: 0})
    assert IO.iodata_to_binary(m1) =~ "not running"
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/commands/stop_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write the verb + wire the CLI**

```elixir
# lib/vzbeam/commands/stop.ex
defmodule VzBeam.Commands.Stop do
  @moduledoc "stop <name> — graceful guest shutdown over SSH (sudo -n shutdown -h now)."
  alias VzBeam.{Manifest, Pidfile, Keys, Leases, Defaults}

  @reap_ms 60_000
  @poll_ms 500

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, default_deps())

  def run([name], deps) do
    with {:ok, m} <- read_manifest(name),
         :ok <- ensure_running(name),
         {:ok, _} <- Keys.ensure(),
         {:ok, ip} <- resolve_ip(m, deps.leases.()) do
      _ = deps.ssh.(ssh_args(ip) ++ ["sudo", "-n", "shutdown", "-h", "now"])
      deadline = System.monotonic_time(:millisecond) + Map.get(deps, :reap_ms, @reap_ms)

      case reap(name, deadline) do
        :stopped -> File.rm(Pidfile.path(name)); {:ok, ["stopped ", name, "\n"]}
        :timeout -> {:error, 1, [name, " did not stop in time; try `vzbeam kill ", name, "`\n"]}
      end
    else
      err -> error(err)
    end
  end

  def run(_, _), do: {:error, 2, "usage: vzbeam stop <name>\n"}

  defp reap(name, deadline) do
    cond do
      not Pidfile.running?(name) -> :stopped
      System.monotonic_time(:millisecond) >= deadline -> :timeout
      true -> Process.sleep(@poll_ms); reap(name, deadline)
    end
  end

  defp ssh_args(ip) do
    ["-i", Keys.private(), "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
     "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5",
     "#{Defaults.values().ssh_user}@#{ip}"]
  end

  defp read_manifest(name) do
    case Manifest.read(name), do: ({:ok, m} -> {:ok, m}; _ -> {:error, :no_such_bundle})
  end

  defp ensure_running(name), do: if(Pidfile.running?(name), do: :ok, else: {:error, :not_running})

  defp resolve_ip(m, leases) do
    case Leases.lookup_ip(leases, m["macAddress"]) do
      nil -> {:error, :no_lease}
      ip -> {:ok, ip}
    end
  end

  defp error({:error, :no_such_bundle}), do: {:error, 1, "stop: no such bundle\n"}
  defp error({:error, :not_running}), do: {:error, 1, "stop: not running\n"}
  defp error({:error, :no_lease}), do: {:error, 1, "stop: no DHCP lease yet (is it networked?)\n"}
  defp error({:error, reason}), do: {:error, 1, ["stop failed: ", inspect(reason), "\n"]}

  defp default_deps do
    %{ssh: fn args -> System.cmd("ssh", args, stderr_to_stdout: true) end,
      leases: &Leases.read/0, reap_ms: @reap_ms}
  end
end
```

```elixir
# lib/vzbeam/cli.ex — add clause + @usage line
  def run(["stop" | rest]), do: VzBeam.Commands.Stop.run(rest)
```
```
    stop <name>        graceful guest shutdown over SSH
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/commands/stop_test.exs test/cli_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/commands/stop.ex test/commands/stop_test.exs lib/vzbeam/cli.ex
git commit -m "feat: stop verb (ssh sudo -n shutdown + bounded reap)"
```

---

## Task 8: `VzBeam.Commands.Kill` — force power-off (+ CLI)

**Files:**
- Create: `lib/vzbeam/commands/kill.ex`, `test/commands/kill_test.exs`
- Modify: `lib/vzbeam/cli.ex`

**Interfaces:**
- Consumes: `Pidfile.{read/1, running?/1, path/1}`.
- Produces: `run(args, deps \\ default_deps()) :: {:ok, iodata} | {:error, code, iodata}`; `deps = %{signal: (sig :: String.t(), pid -> {String.t(), non_neg_integer}), reap_ms: pos_integer}`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/commands/kill_test.exs
defmodule VzBeam.Commands.KillTest do
  use ExUnit.Case, async: false
  alias VzBeam.Commands.Kill

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-kill-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    File.mkdir_p!(Path.join(home, "dev"))
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    :ok
  end

  test "SIGTERM stops a real running child and cleans vm.pid" do
    {out, 0} = System.cmd("sh", ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"])
    pid = out |> String.trim() |> String.to_integer()
    :ok = VzBeam.Pidfile.write("dev", pid)

    assert {:ok, msg} = Kill.run(["dev"], VzBeam.Commands.Kill.default_deps())
    assert IO.iodata_to_binary(msg) =~ "killed dev"
    refute VzBeam.Pidfile.running?("dev")
  end

  test "escalates to SIGKILL on timeout (injected signal records the escalation)" do
    :ok = VzBeam.Pidfile.write("dev", System.pid())  # alive; our fake signal won't kill the BEAM
    parent = self()
    deps = %{signal: fn sig, _pid -> send(parent, {:sig, sig}); {"", 0} end, reap_ms: 0}

    assert {:ok, msg} = Kill.run(["dev"], deps)
    assert IO.iodata_to_binary(msg) =~ "SIGKILL"
    assert_received {:sig, "-TERM"}
    assert_received {:sig, "-KILL"}
    File.rm(VzBeam.Pidfile.path("dev"))
  end

  test "cleans a stale vm.pid and reports not running" do
    :ok = File.write!(VzBeam.Pidfile.path("dev"),
      Jason.encode!(%{"pid" => 999_999, "startedAt" => "x", "bundle" => "dev"}))
    assert {:ok, msg} = Kill.run(["dev"], VzBeam.Commands.Kill.default_deps())
    assert IO.iodata_to_binary(msg) =~ "not running"
    refute File.exists?(VzBeam.Pidfile.path("dev"))
  end

  test "errors on a VM with no vm.pid" do
    assert {:error, 1, msg} = Kill.run(["dev"], VzBeam.Commands.Kill.default_deps())
    assert IO.iodata_to_binary(msg) =~ "no such running VM"
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/commands/kill_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write the verb + wire the CLI**

```elixir
# lib/vzbeam/commands/kill.ex
defmodule VzBeam.Commands.Kill do
  @moduledoc "kill <name> — force power-off: SIGTERM to the vz run pid (sidecar traps), SIGKILL last resort. Never pkill."
  alias VzBeam.Pidfile

  @reap_ms 20_000
  @poll_ms 200

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, default_deps())

  def run([name], deps) do
    case Pidfile.read(name) do
      {:ok, %{"pid" => pid}} ->
        # Re-confirm liveness (start-time match) immediately before signaling (no PID-reuse hit).
        if Pidfile.running?(name) do
          deps.signal.("-TERM", pid)
          deadline = System.monotonic_time(:millisecond) + Map.get(deps, :reap_ms, @reap_ms)

          case reap(name, deadline) do
            :stopped ->
              File.rm(Pidfile.path(name)); {:ok, ["killed ", name, "\n"]}

            :timeout ->
              deps.signal.("-KILL", pid); File.rm(Pidfile.path(name)); {:ok, ["killed ", name, " (SIGKILL)\n"]}
          end
        else
          File.rm(Pidfile.path(name)); {:ok, [name, " was not running (cleaned stale vm.pid)\n"]}
        end

      _ ->
        {:error, 1, ["no such running VM: ", name, "\n"]}
    end
  end

  def run(_, _), do: {:error, 2, "usage: vzbeam kill <name>\n"}

  defp reap(name, deadline) do
    cond do
      not Pidfile.running?(name) -> :stopped
      System.monotonic_time(:millisecond) >= deadline -> :timeout
      true -> Process.sleep(@poll_ms); reap(name, deadline)
    end
  end

  @doc false
  def default_deps do
    %{signal: fn sig, pid -> System.cmd("kill", [sig, to_string(pid)], stderr_to_stdout: true) end,
      reap_ms: @reap_ms}
  end
end
```

```elixir
# lib/vzbeam/cli.ex — add clause + @usage line
  def run(["kill" | rest]), do: VzBeam.Commands.Kill.run(rest)
```
```
    kill <name>        force power-off (SIGTERM, then SIGKILL)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/commands/kill_test.exs test/cli_test.exs`
Expected: PASS (real SIGTERM stop; SIGKILL escalation; stale clean; no-pidfile error).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/commands/kill.ex test/commands/kill_test.exs lib/vzbeam/cli.ex
git commit -m "feat: kill verb (SIGTERM -> SIGKILL, never pkill)"
```

---

## Task 9: `VzBeam.Commands.Ssh` (+ CLI) + full suite + escript smoke-run

**Files:**
- Create: `lib/vzbeam/commands/ssh.ex`, `test/commands/ssh_test.exs`
- Modify: `lib/vzbeam/cli.ex`

**Interfaces:**
- Consumes: `Manifest.read/1`, `Keys.ensure/0` + `Keys.private/0`, `Leases.{read/0, lookup_ip/2}`, `Defaults.values/0`.
- Produces: `run(args, deps \\ default_deps()) :: {:ok, iodata} | {:error, code, iodata}`; `deps = %{leases, run_cmd: ([String.t()] -> {String.t(), non_neg_integer}), interactive: ([String.t()] -> non_neg_integer)}`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/commands/ssh_test.exs
defmodule VzBeam.Commands.SshTest do
  use ExUnit.Case, async: false
  alias VzBeam.Commands.Ssh

  @mac "5e:aa:bb:cc:dd:ee"

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-ssh-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    dir = Path.join(home, "dev")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "config.json"), Jason.encode!(%{"name" => "dev", "macAddress" => @mac}))
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    :ok
  end

  defp leases, do: "{\n\tname=dev\n\tip_address=192.168.64.7\n\thw_address=1,#{@mac}\n}\n"

  test "one-shot `-- cmd` builds key-based argv and propagates output + exit code" do
    parent = self()
    run_cmd = fn args -> send(parent, {:cmd, args}); {"hi\n", 0} end
    deps = %{leases: fn -> leases() end, run_cmd: run_cmd, interactive: fn _ -> 0 end}

    assert {:ok, "hi\n"} = Ssh.run(["dev", "--", "uname", "-a"], deps)
    assert_received {:cmd, args}
    joined = Enum.join(args, " ")
    assert joined =~ "BatchMode=yes" and joined =~ "admin@192.168.64.7"
    assert List.last(args) == "-a" and Enum.at(args, -2) == "uname"
  end

  test "one-shot propagates a non-zero remote exit code" do
    deps = %{leases: fn -> leases() end, run_cmd: fn _ -> {"boom\n", 3} end, interactive: fn _ -> 0 end}
    assert {:error, 3, "boom\n"} = Ssh.run(["dev", "--", "false"], deps)
  end

  test "interactive (no cmd) returns the ssh exit code via the injected port runner" do
    deps = %{leases: fn -> leases() end, run_cmd: fn _ -> {"", 0} end, interactive: fn _args -> 0 end}
    assert {:ok, ""} = Ssh.run(["dev"], deps)

    deps2 = %{deps | interactive: fn _ -> 7 end}
    assert {:error, 7, ""} = Ssh.run(["dev"], deps2)
  end

  test "errors when there is no lease" do
    deps = %{leases: fn -> "" end, run_cmd: fn _ -> {"", 0} end, interactive: fn _ -> 0 end}
    assert {:error, 1, msg} = Ssh.run(["dev"], deps)
    assert IO.iodata_to_binary(msg) =~ "no DHCP lease"
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/commands/ssh_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write the verb + wire the CLI**

```elixir
# lib/vzbeam/commands/ssh.ex
defmodule VzBeam.Commands.Ssh do
  @moduledoc "ssh <name> [-- cmd…] — key-based ssh; interactive shell (Port :nouse_stdio) or one-shot command."
  alias VzBeam.{Manifest, Keys, Leases, Defaults}

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, default_deps())

  def run([name | rest], deps) do
    with {:ok, m} <- read_manifest(name),
         {:ok, _} <- Keys.ensure(),
         {:ok, ip} <- resolve_ip(m, deps.leases.()) do
      base = ssh_args(ip)

      case rest do
        ["--" | cmd] when cmd != [] -> oneshot(base ++ cmd, deps)
        [] -> interactive(base, deps)
        _ -> {:error, 2, "usage: vzbeam ssh <name> [-- cmd…]\n"}
      end
    else
      err -> error(err)
    end
  end

  def run(_, _), do: {:error, 2, "usage: vzbeam ssh <name> [-- cmd…]\n"}

  defp oneshot(args, deps) do
    case deps.run_cmd.(args) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, status, out}
    end
  end

  defp interactive(args, deps) do
    case deps.interactive.(args) do
      0 -> {:ok, ""}
      status -> {:error, status, ""}
    end
  end

  @doc false
  def interactive_port(args) do
    ssh = System.find_executable("ssh")
    port = Port.open({:spawn_executable, ssh}, [:nouse_stdio, :exit_status, args: args])

    receive do
      {^port, {:exit_status, s}} -> s
    end
  end

  defp ssh_args(ip) do
    ["-i", Keys.private(), "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
     "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5",
     "#{Defaults.values().ssh_user}@#{ip}"]
  end

  defp read_manifest(name) do
    case Manifest.read(name), do: ({:ok, m} -> {:ok, m}; _ -> {:error, :no_such_bundle})
  end

  defp resolve_ip(m, leases) do
    case Leases.lookup_ip(leases, m["macAddress"]) do
      nil -> {:error, :no_lease}
      ip -> {:ok, ip}
    end
  end

  defp error({:error, :no_such_bundle}), do: {:error, 1, "ssh: no such bundle\n"}
  defp error({:error, :no_lease}), do: {:error, 1, "ssh: no DHCP lease yet (is it networked? bridge100)\n"}
  defp error({:error, reason}), do: {:error, 1, ["ssh failed: ", inspect(reason), "\n"]}

  defp default_deps do
    %{leases: &Leases.read/0,
      run_cmd: fn args -> System.cmd("ssh", args, stderr_to_stdout: false) end,
      interactive: &interactive_port/1}
  end
end
```

```elixir
# lib/vzbeam/cli.ex — add clause + @usage line
  def run(["ssh" | rest]), do: VzBeam.Commands.Ssh.run(rest)
```
```
    ssh <name> [-- cmd…]  ssh into a VM (interactive or one-shot)
```

- [ ] **Step 4: Run the full suite + build the escript**

Run: `mix test && mix escript.build`
Expected: all green; `./vzbeam` builds.

- [ ] **Step 5: Escript smoke-run (the real detach/handshake/kill against the fake — the Plan-2 lesson)**

```bash
# Exercise the REAL Daemon detach + run.log handshake + kill that ExUnit can't fully prove.
export VZBEAM_HOME=$(mktemp -d)
export VZBEAM_VZ="$PWD/test/support/fake_vz"
mkdir -p "$VZBEAM_HOME/dev"
printf '{"name":"dev","macAddress":"5e:aa:bb:cc:dd:ee","cpuCount":2,"memoryBytes":2147483648}' > "$VZBEAM_HOME/dev/config.json"

./vzbeam run dev                      # spawns fake_vz run (idle), writes vm.pid, handshake sees started
PID=$(grep -o '"pid":[0-9]*' "$VZBEAM_HOME/dev/vm.pid" | head -1 | cut -d: -f2)
ps -p "$PID" >/dev/null && echo "SMOKE: detached fake_vz alive (pid $PID) ✓"
./vzbeam kill dev                     # SIGTERM -> fake traps -> guest_stopped -> exit; vm.pid removed
ps -p "$PID" >/dev/null 2>&1 && echo "SMOKE: still alive (BAD)" || echo "SMOKE: stopped + cleaned ✓"
test -f "$VZBEAM_HOME/dev/vm.pid" && echo "SMOKE: stale vm.pid (BAD)" || echo "SMOKE: vm.pid removed ✓"
rm -rf "$VZBEAM_HOME"; unset VZBEAM_HOME VZBEAM_VZ
```
Expected: "detached fake_vz alive ✓", "stopped + cleaned ✓", "vm.pid removed ✓".

- [ ] **Step 6: Commit**

```bash
git add lib/vzbeam/commands/ssh.ex test/commands/ssh_test.exs lib/vzbeam/cli.ex
git commit -m "feat: ssh verb (interactive Port :nouse_stdio + one-shot)"
```

---

## Self-Review (completed during planning)

- **Spec coverage:** `run` → Task 6; `stop` → 7; `kill` → 8; `ssh` (interactive + `-- cmd`) → 9; host-wide `run.lock` → 1; 2-VM cap → 6 (`count_running` under the lock); `Port`-streamed `restore` + stderr tail → 5; SSH keys → 3; `--share` → 4; detached spawn → 2; fake_vz run/restore modes → 5/6. Codex folds: `Pidfile.process_start` unwrap (#1, Task 1); no `:ok =`-match on `Pidfile.write` (#2, Task 6 `:spawn_exited`); `started`+live re-check (#3, Task 6 `poll`); `sudo -n`/`BatchMode=yes` (#4, Tasks 7/9); launch-pid framing (#5, Task 2); `Lock` `mkdir_p` (#6, Task 1); `:lock_corrupt` (#7, Task 1); unconditional `vm.pid` cleanup (#8, Task 6 `cleanup`); kill start-time re-check (#9, Task 8).
- **Placeholder scan:** none — every step carries real code/commands.
- **Type consistency:** `with_lock/1` returns `{:ok, inner}` where `inner ∈ {{:ok,pid},{:error,:at_capacity},{:spawn_exited,pid}}` — unwrapped in `Run.launch`. `Daemon.spawn_detached/2 :: {:ok, pid}` consumed by `deps.spawn` in Task 6. `Sidecar.restore/1` (now `on_event`-arg) stays compatible with `New`'s injected `restore`. `Pidfile.process_start/1 :: {:ok, String}|:error` consumed by `Lock` (Task 1) and `Pidfile.running?` (Tasks 6/7/8). `Keys.private/0` used by Tasks 7/9. `Defaults.values().ssh_user` used by Tasks 7/9.
- **Note:** the interactive-ssh tty hand-off is proven by the §2 pty spike; the ExUnit test injects `interactive` and the real `interactive_port/1` is exercised by manual validation (spec §13).

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-06-24-vzbeam-run-lifecycle.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — fresh subagent per task, two-stage review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session via executing-plans, batch with checkpoints.

**Which approach?**
