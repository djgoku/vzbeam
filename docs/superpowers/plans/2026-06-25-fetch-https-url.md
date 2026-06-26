# `vzbeam fetch https://…ipsw` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `vzbeam fetch` accept an `https://…ipsw` URL (alongside `latest` and a local PATH), downloading the image, identifying it via `image-info`, and caching it by build.

**Architecture:** Pure Elixir in `VzBeam.Cache`. The Swift `image-info` sidecar can't read a remote IPSW's metadata, so for a URL we download-first, then run the existing `image_info` dep on the local file to learn `build`/`version`, then place it exactly like the `latest`/PATH flows. `build` stays the canonical cache key; an exact normalized-URL match is only a pre-download bandwidth shortcut.

**Tech Stack:** Elixir, ExUnit, `curl` (existing `download/2` helper), `URI` stdlib.

## Global Constraints

- `https://` only — `http://` and other schemes are rejected with `{:error, :unsupported_url_scheme}`. No Swift change.
- Dependency injection: `VzBeam.Cache.ensure/2` takes `deps` with keys `image_info`, `download`, `copy`. Tests stub these; never hit the network or real `curl` in tests.
- No `.ipsw` path-suffix requirement on the URL — content is validated by `image_info`, not the filename.
- Stored index entry for a URL fetch has `source: "url"` and `url:` set to the **normalized** request URL (fragment stripped), not the CDN redirect target.
- Pending download file is named `url-fetch-<unique>.ipsw` in the cache dir.
- Deferred (do NOT implement here): pre-download size/disk guard, concurrency locking, crash-safe stale-pending cleanup. See spec "Known limitations".

---

## File Structure

- **Modify** `lib/vzbeam/cache.ex` — add `classify/1`, `normalize_url/1`, `ensure_url/2`, `acquire_url/2`, `identify_url/3`, `place_url/3`, `lookup_by_url/1`; rename the current `ensure/2` body into `ensure_local/2` and dispatch from `ensure/2`. Reuse `put_index/2`, `size_sane/1`, `validate_build/1`, `download/2`, `lookup/1`, `dir/0`, `read_index/0`.
- **Modify** `lib/vzbeam/commands/fetch.ex` — usage string + `@moduledoc` → `<latest|PATH|URL>`.
- **Modify** `lib/vzbeam/cli.ex` — the `fetch` help line → `<latest|PATH|URL>`.
- **Modify** `test/cache_test.exs` — add URL-branch tests.
- **Modify** `test/commands/fetch_test.exs` — assert the usage string mentions `URL`.

> Note: `cli.ex` also has a `new <name> --image <latest|PATH>` line. `new --image` routing is **out of scope** for this plan — leave that line unchanged.

---

## Task 1: URL classification + happy-path fetch

Add the URL branch to `ensure/2`: classify the spec, normalize the URL (host check only for now), download to a unique pending file, identify it via the `image_info` dep (overriding `url`/`source`), then rename + index as `:fetched`. Reject `http://`. Clean up the pending file on any failure.

**Files:**
- Modify: `lib/vzbeam/cache.ex`
- Test: `test/cache_test.exs`

**Interfaces:**
- Consumes: existing `put_index/2`, `size_sane/1`, `validate_build/1`, `lookup/1`, `dir/0`, the `download/2` curl helper, and the injected `deps.image_info` / `deps.download`.
- Produces:
  - `ensure/2` now returns `{:error, :unsupported_url_scheme}` for `http://…`, routes `https://…` to `ensure_url/2`, and routes everything else to the unchanged local flow.
  - `ensure_url(spec, deps) :: {:ok, :fetched, map} | {:error, term}` (dedup/reconcile added in Task 3).
  - Index entry for a URL fetch carries `"source" => "url"` and `"url" => <normalized request URL>`.

- [ ] **Step 1: Write the failing tests**

Add to `test/cache_test.exs` (inside the module, after the existing tests). Add a URL-specific deps helper near the top, after the existing `deps/1`:

```elixir
  defp url_deps(build \\ "25F80") do
    %{
      image_info: fn _path ->
        {:ok, %{version: "26.5.1", build: build, url: "https://cdn.example/redirect.ipsw", source: "local"}}
      end,
      download: fn _url, dst -> File.write(dst, "IPSWBYTES") end,
      copy: fn _s, _d -> {:error, :should_not_copy} end
    }
  end
```

```elixir
  test "ensure fetches an https URL, overriding source/url and indexing by build" do
    assert {:ok, :fetched, e} = Cache.ensure("https://host.example/x.ipsw", url_deps())
    assert e["build"] == "25F80"
    assert e["file"] == "25F80.ipsw"
    assert e["source"] == "url"
    assert e["url"] == "https://host.example/x.ipsw"
    assert File.regular?(Path.join(Cache.dir(), "25F80.ipsw"))
  end

  test "ensure rejects a non-https URL scheme" do
    assert {:error, :unsupported_url_scheme} = Cache.ensure("http://host.example/x.ipsw", url_deps())
  end

  test "ensure rejects an https URL with no host" do
    assert {:error, :bad_url} = Cache.ensure("https://", url_deps())
  end

  test "ensure cleans up the pending file when image-info fails on a URL fetch" do
    deps = %{url_deps() | image_info: fn _ -> {:error, :boom} end}
    assert {:error, :boom} = Cache.ensure("https://host.example/x.ipsw", deps)
    assert Path.wildcard(Path.join(Cache.dir(), "url-fetch-*.ipsw")) == []
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cache_test.exs`
Expected: the four new tests FAIL (the URL spec currently falls into the local flow — `image_info` is called with the raw URL string and there is no `:url`/scheme handling).

- [ ] **Step 3: Implement classification + the happy-path URL branch**

In `lib/vzbeam/cache.ex`, replace the current `ensure/2`:

```elixir
  @spec ensure(String.t(), map) :: {:ok, atom, map} | {:error, term}
  def ensure(spec, deps \\ default_deps()) do
    with {:ok, info} <- deps.image_info.(spec),
         :ok <- validate_build(info.build) do
      final = Path.join(dir(), "#{info.build}.ipsw")

      case lookup(info.build) do
        {:ok, entry} -> {:ok, :cached, entry}
        :error -> if File.regular?(final),
                    do: with({:ok, e} <- put_index(info, final), do: {:ok, :reconciled, e}),
                    else: acquire(spec, info, final, deps)
      end
    end
  end
```

with a dispatcher plus the renamed local body:

```elixir
  @spec ensure(String.t(), map) :: {:ok, atom, map} | {:error, term}
  def ensure(spec, deps \\ default_deps()) do
    case classify(spec) do
      :url -> ensure_url(spec, deps)
      :bad_scheme -> {:error, :unsupported_url_scheme}
      :local -> ensure_local(spec, deps)
    end
  end

  defp classify(spec) do
    cond do
      String.starts_with?(spec, "https://") -> :url
      String.starts_with?(spec, "http://") -> :bad_scheme
      true -> :local
    end
  end

  defp ensure_local(spec, deps) do
    with {:ok, info} <- deps.image_info.(spec),
         :ok <- validate_build(info.build) do
      final = Path.join(dir(), "#{info.build}.ipsw")

      case lookup(info.build) do
        {:ok, entry} -> {:ok, :cached, entry}
        :error -> if File.regular?(final),
                    do: with({:ok, e} <- put_index(info, final), do: {:ok, :reconciled, e}),
                    else: acquire(spec, info, final, deps)
      end
    end
  end

  # URL fetch: download first (the sidecar can't read a remote IPSW's metadata),
  # then identify the local file. `build` stays the canonical key.
  defp ensure_url(spec, deps) do
    with {:ok, url} <- normalize_url(spec), do: acquire_url(url, deps)
  end

  defp normalize_url(spec) do
    uri = URI.parse(spec)
    if uri.host in [nil, ""], do: {:error, :bad_url}, else: {:ok, URI.to_string(uri)}
  end

  defp acquire_url(url, deps) do
    pending = Path.join(dir(), "url-fetch-#{System.unique_integer([:positive])}.ipsw")

    with :ok <- File.mkdir_p(dir()),
         :ok <- deps.download.(url, pending),
         :ok <- size_sane(pending),
         {:ok, info} <- identify_url(pending, url, deps),
         :ok <- validate_build(info.build) do
      place_url(pending, Path.join(dir(), "#{info.build}.ipsw"), info)
    else
      err -> File.rm(pending); err
    end
  end

  # image-info reports the CDN redirect URL + "local"; override with the original
  # request URL + "url" so a later fetch of the same URL dedups (Task 3).
  defp identify_url(pending, url, deps) do
    with {:ok, info} <- deps.image_info.(pending), do: {:ok, %{info | url: url, source: "url"}}
  end

  defp place_url(pending, final, info) do
    with :ok <- File.rename(pending, final),
         {:ok, entry} <- put_index(info, final) do
      {:ok, :fetched, entry}
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/cache_test.exs`
Expected: PASS (all existing cache tests plus the four new ones).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/cache.ex test/cache_test.exs
git commit -m "feat(fetch): https URL branch — download, identify, index by build"
```

---

## Task 2: URL validation hardening (userinfo + fragment)

Reject credentials embedded in the URL, and strip the fragment before storing/comparing so `…/x.ipsw#a` and `…/x.ipsw#b` are the same image.

**Files:**
- Modify: `lib/vzbeam/cache.ex` (`normalize_url/1` only)
- Test: `test/cache_test.exs`

**Interfaces:**
- Consumes: `normalize_url/1` from Task 1.
- Produces: `normalize_url/1` now returns `{:error, :url_userinfo_not_allowed}` for `user:pass@`, and returns a fragment-free URL string otherwise.

- [ ] **Step 1: Write the failing tests**

Add to `test/cache_test.exs`:

```elixir
  test "ensure rejects an https URL carrying userinfo" do
    assert {:error, :url_userinfo_not_allowed} =
             Cache.ensure("https://user:pass@host.example/x.ipsw", url_deps())
  end

  test "ensure strips the fragment when storing a URL entry" do
    assert {:ok, :fetched, e} = Cache.ensure("https://host.example/x.ipsw#part1", url_deps())
    assert e["url"] == "https://host.example/x.ipsw"
    refute e["url"] =~ "#"
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cache_test.exs`
Expected: both new tests FAIL — userinfo is currently accepted, and the stored `url` still contains `#part1`.

- [ ] **Step 3: Implement the validation**

In `lib/vzbeam/cache.ex`, replace `normalize_url/1` from Task 1:

```elixir
  defp normalize_url(spec) do
    uri = URI.parse(spec)

    cond do
      uri.host in [nil, ""] -> {:error, :bad_url}
      uri.userinfo not in [nil, ""] -> {:error, :url_userinfo_not_allowed}
      true -> {:ok, URI.to_string(%{uri | fragment: nil})}
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/cache_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/cache.ex test/cache_test.exs
git commit -m "feat(fetch): reject URL userinfo and strip fragment before caching"
```

---

## Task 3: URL dedup + build reconcile

Skip the download when the exact normalized URL is already cached. And when a *different* URL resolves to an already-cached build (or an orphaned `{build}.ipsw` exists), discard the pending download instead of re-indexing.

**Files:**
- Modify: `lib/vzbeam/cache.ex` (`ensure_url/2` and `place_url/3`; add `lookup_by_url/1`)
- Test: `test/cache_test.exs`

**Interfaces:**
- Consumes: `read_index/0`, `dir/0`, `lookup/1`, `put_index/2` (all existing); `ensure_url/2`, `place_url/3` from Task 1.
- Produces:
  - `lookup_by_url(url) :: {:ok, map} | :error` — index entry whose `"url"` matches exactly **and** whose `{build}.ipsw` file exists.
  - `ensure_url/2` returns `{:ok, :cached, entry}` with no download on a URL hit.
  - `place_url/3` returns `{:ok, :cached, entry}` (build already indexed) or `{:ok, :reconciled, entry}` (orphan file present), discarding `pending` in both cases; else `{:ok, :fetched, entry}`.

- [ ] **Step 1: Write the failing tests**

Add to `test/cache_test.exs`:

```elixir
  test "ensure dedups a repeat URL fetch without downloading again" do
    assert {:ok, :fetched, _} = Cache.ensure("https://host.example/x.ipsw", url_deps())

    no_dl = %{url_deps() | download: fn _u, _d -> {:error, :should_not_download} end}
    assert {:ok, :cached, e} = Cache.ensure("https://host.example/x.ipsw", no_dl)
    assert e["build"] == "25F80"
  end

  test "ensure dedups two URL fragments of the same image without re-downloading" do
    assert {:ok, :fetched, _} = Cache.ensure("https://host.example/x.ipsw#a", url_deps())

    no_dl = %{url_deps() | download: fn _u, _d -> {:error, :should_not_download} end}
    assert {:ok, :cached, _} = Cache.ensure("https://host.example/x.ipsw#b", no_dl)
  end

  test "ensure discards the pending download when a different URL resolves to a cached build" do
    assert {:ok, :fetched, _} = Cache.ensure("https://host.example/a.ipsw", url_deps())
    # Different URL, same build -> URL scan misses, downloads, then build is already cached.
    assert {:ok, :cached, e} = Cache.ensure("https://host.example/b.ipsw", url_deps())
    assert e["build"] == "25F80"
    assert Path.wildcard(Path.join(Cache.dir(), "url-fetch-*.ipsw")) == []
  end

  test "ensure reconciles an orphaned final file reached via a URL fetch" do
    File.mkdir_p!(Cache.dir())
    File.write!(Path.join(Cache.dir(), "25F80.ipsw"), "ORPHAN")
    assert {:ok, :reconciled, e} = Cache.ensure("https://host.example/x.ipsw", url_deps())
    assert e["build"] == "25F80"
    assert Path.wildcard(Path.join(Cache.dir(), "url-fetch-*.ipsw")) == []
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cache_test.exs`
Expected: the dedup tests FAIL (the repeat call currently re-downloads — and the `no_dl` stub returns `{:error, :should_not_download}`, so the second `ensure` errors instead of returning `:cached`); the reconcile test FAILS (Task 1's `place_url` blindly renames over / re-indexes).

- [ ] **Step 3: Implement dedup + reconcile**

In `lib/vzbeam/cache.ex`, replace `ensure_url/2`:

```elixir
  defp ensure_url(spec, deps) do
    with {:ok, url} <- normalize_url(spec) do
      case lookup_by_url(url) do
        {:ok, entry} -> {:ok, :cached, entry}
        :error -> acquire_url(url, deps)
      end
    end
  end

  # Pre-download shortcut only: an exact normalized-URL hit whose file still exists.
  defp lookup_by_url(url) do
    entry = read_index()["images"] |> Map.values() |> Enum.find(&(&1["url"] == url))

    if entry && File.regular?(Path.join(dir(), entry["file"])),
      do: {:ok, entry},
      else: :error
  end
```

and replace `place_url/3`:

```elixir
  defp place_url(pending, final, info) do
    case lookup(info.build) do
      {:ok, entry} ->
        File.rm(pending)
        {:ok, :cached, entry}

      :error ->
        if File.regular?(final) do
          File.rm(pending)
          with {:ok, e} <- put_index(info, final), do: {:ok, :reconciled, e}
        else
          with :ok <- File.rename(pending, final),
               {:ok, entry} <- put_index(info, final) do
            {:ok, :fetched, entry}
          end
        end
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/cache_test.exs`
Expected: PASS (all cache tests).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/cache.ex test/cache_test.exs
git commit -m "feat(fetch): dedup URL fetches by URL and reconcile by build"
```

---

## Task 4: CLI help text → `<latest|PATH|URL>`

Update the user-facing usage/help so the new spec kind is documented.

**Files:**
- Modify: `lib/vzbeam/commands/fetch.ex`
- Modify: `lib/vzbeam/cli.ex`
- Test: `test/commands/fetch_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Fetch.run/2` arity-mismatch path returns a usage string containing `URL`.

- [ ] **Step 1: Write the failing test**

Replace the existing "usage error with no spec" test in `test/commands/fetch_test.exs`:

```elixir
  test "usage error with no spec mentions the URL spec kind" do
    assert {:error, 2, msg} = VzBeam.Commands.Fetch.run([], %{ensure: fn _ -> :unused end})
    assert IO.iodata_to_binary(msg) =~ "URL"
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/commands/fetch_test.exs`
Expected: FAIL — the usage string is currently `usage: vzbeam fetch <latest|PATH>` (no `URL`).

- [ ] **Step 3: Update the usage/help strings**

In `lib/vzbeam/commands/fetch.ex`, line 2 (`@moduledoc`) and line 14 (the usage clause):

```elixir
  @moduledoc "fetch <latest|PATH|URL> — download/cache a restore image."
```

```elixir
  def run(_, _), do: {:error, 2, "usage: vzbeam fetch <latest|PATH|URL>\n"}
```

In `lib/vzbeam/cli.ex`, the `fetch` line in `@usage` (line 10):

```elixir
    fetch <latest|PATH|URL> download/cache a restore image
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/commands/fetch_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/commands/fetch.ex lib/vzbeam/cli.ex test/commands/fetch_test.exs
git commit -m "docs(fetch): document the URL spec kind in usage/help"
```

---

## Final verification

- [ ] Run the full suite: `mix test` — expect all green (128 prior + new URL tests).
- [ ] Compile cleanly with warnings as errors if the project uses it: `mix compile --warnings-as-errors`.
- [ ] **Hardware verification (per spec):** on real Apple Silicon, run `vzbeam fetch https://…/UniversalMac_…_Restore.ipsw` against a genuine Apple IPSW URL and confirm it downloads, identifies, indexes (check `vzbeam images`), and that a repeat fetch reports `already cached` without re-downloading. This confirms `VZMacOSRestoreImage.load(from:)` accepts the `url-fetch-<unique>.ipsw` temp name. This build host cannot boot guests, but `image-info` reads metadata only and is already exercised by the path-copy flow.
