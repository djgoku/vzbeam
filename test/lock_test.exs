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
