defmodule VzBeam.PendingBundleTest do
  use ExUnit.Case, async: false
  alias VzBeam.{Home, PendingBundle}

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-pending-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)

    on_exit(fn ->
      System.delete_env("VZBEAM_HOME")
      File.rm_rf!(home)
    end)

    {:ok, home: home, self_pid: System.pid() |> String.to_integer()}
  end

  defp deps(starts) do
    %{
      with_lock: fn fun -> {:ok, fun.()} end,
      process_start: fn pid -> Map.get(starts, pid, :error) end
    }
  end

  defp owner_path(name), do: Path.join(Home.bundle_dir(name) <> ".pending", "install-owner.json")

  defp seed_pending(name, owner) do
    path = Home.bundle_dir(name) <> ".pending"
    File.mkdir_p!(path)
    File.write!(Path.join(path, "sentinel"), "keep")

    if owner != :missing do
      body = if is_map(owner), do: Jason.encode!(owner), else: owner
      File.write!(Path.join(path, "install-owner.json"), body)
    end

    path
  end

  test "claim creates and records its owner before returning", %{self_pid: pid} do
    assert {:ok, claim} = PendingBundle.claim("obsd", deps(%{pid => {:ok, "self-start"}}))
    assert claim.path == Home.bundle_dir("obsd") <> ".pending"
    assert claim.owner == %{"pid" => pid, "startedAt" => "self-start"}
    assert Jason.decode!(File.read!(owner_path("obsd"))) == claim.owner
  end

  # An ownerless .pending reads as :pending_owner_unreadable to every later claim, so a
  # claim whose owner write fails must not leave the directory it just created behind.
  test "a failed owner write removes the new claim directory", %{self_pid: pid} do
    starts = %{pid => {:ok, "self-start"}}
    failing = Map.put(deps(starts), :write_owner, fn _path, _body -> {:error, :enospc} end)

    assert {:error, :enospc} = PendingBundle.claim("obsd", failing)
    refute File.exists?(Home.bundle_dir("obsd") <> ".pending")
    assert {:ok, _claim} = PendingBundle.claim("obsd", deps(starts))
  end

  test "a failed owner write while reclaiming a stale claim removes its directory", %{
    self_pid: pid
  } do
    path = seed_pending("obsd", %{"pid" => 999_999, "startedAt" => "gone"})
    starts = %{pid => {:ok, "self-start"}}
    failing = Map.put(deps(starts), :write_owner, fn _path, _body -> {:error, :enospc} end)

    assert {:error, :enospc} = PendingBundle.claim("obsd", failing)
    refute File.exists?(path)
  end

  test "claim rechecks final existence while locked and never overwrites it", %{
    home: home,
    self_pid: pid
  } do
    final = Path.join(home, "obsd")
    File.mkdir_p!(final)
    File.write!(Path.join(final, "config.json"), "{}")

    assert {:error, :exists} =
             PendingBundle.claim("obsd", deps(%{pid => {:ok, "self-start"}}))

    assert File.read!(Path.join(final, "config.json")) == "{}"
    refute File.exists?(final <> ".pending")
  end

  test "claim rejects a bare final directory before creating pending state", %{
    home: home,
    self_pid: pid
  } do
    final = Path.join(home, "obsd")
    File.mkdir_p!(final)
    File.write!(Path.join(final, "sentinel"), "keep")

    assert {:error, :exists} =
             PendingBundle.claim("obsd", deps(%{pid => {:ok, "self-start"}}))

    assert File.read!(Path.join(final, "sentinel")) == "keep"
    refute File.exists?(final <> ".pending")
  end

  test "a matching live owner blocks the claim without deleting pending bytes", %{self_pid: pid} do
    pending = seed_pending("obsd", %{"pid" => 42, "startedAt" => "live"})

    assert {:error, :creation_in_progress} =
             PendingBundle.claim(
               "obsd",
               deps(%{pid => {:ok, "self-start"}, 42 => {:ok, "live"}})
             )

    assert File.read!(Path.join(pending, "sentinel")) == "keep"
  end

  test "a valid dead owner is reclaimed and replaced", %{self_pid: pid} do
    pending = seed_pending("obsd", %{"pid" => 42, "startedAt" => "old"})

    assert {:ok, claim} =
             PendingBundle.claim("obsd", deps(%{pid => {:ok, "self-start"}, 42 => :error}))

    refute File.exists?(Path.join(pending, "sentinel"))
    assert Jason.decode!(File.read!(owner_path("obsd"))) == claim.owner
  end

  test "missing or malformed owners are preserved for operator inspection", %{self_pid: pid} do
    for owner <- [:missing, "not-json"] do
      File.rm_rf!(Home.bundle_dir("obsd") <> ".pending")
      pending = seed_pending("obsd", owner)

      assert {:error, :pending_owner_unreadable} =
               PendingBundle.claim("obsd", deps(%{pid => {:ok, "self-start"}}))

      assert File.read!(Path.join(pending, "sentinel")) == "keep"
    end
  end

  test "cleanup matches ownership and deletes only while holding the lock", %{self_pid: pid} do
    assert {:ok, claim} = PendingBundle.claim("obsd", deps(%{pid => {:ok, "self-start"}}))
    parent = self()

    locked = fn fun ->
      result = fun.()
      send(parent, {:cleanup_inside_lock, File.exists?(claim.path)})
      {:ok, result}
    end

    assert :ok = PendingBundle.cleanup(claim, locked)
    assert_received {:cleanup_inside_lock, false}

    assert {:ok, changed} =
             PendingBundle.claim("obsd", deps(%{pid => {:ok, "self-start"}}))

    File.write!(owner_path("obsd"), Jason.encode!(%{"pid" => 9, "startedAt" => "other"}))
    assert {:error, :owner_mismatch} = PendingBundle.cleanup(changed, locked)
    assert File.exists?(changed.path)
  end

  test "promote rechecks final existence and completes rename under the lock", %{
    home: home,
    self_pid: pid
  } do
    assert {:ok, claim} = PendingBundle.claim("obsd", deps(%{pid => {:ok, "self-start"}}))
    File.write!(Path.join(claim.path, "config.json"), "{}")
    parent = self()

    locked = fn fun ->
      result = fun.()

      send(
        parent,
        {:promote_inside_lock, result, File.exists?(Path.join(home, "obsd")),
         File.exists?(Path.join([home, "obsd", "install-owner.json"]))}
      )

      {:ok, result}
    end

    assert :ok = PendingBundle.promote(claim, locked)
    assert_received {:promote_inside_lock, :ok, true, false}
    refute File.exists?(claim.path)

    assert {:ok, second} =
             PendingBundle.claim("next", deps(%{pid => {:ok, "self-start"}}))

    final = Path.join(home, "next")
    File.mkdir_p!(final)
    File.write!(Path.join(final, "config.json"), "existing")
    assert {:error, :exists} = PendingBundle.promote(second, fn fun -> {:ok, fun.()} end)
    assert File.exists?(second.path)
    assert File.read!(Path.join(final, "config.json")) == "existing"
  end

  test "lock errors propagate without touching pending state", %{self_pid: pid} do
    for reason <- [:lock_timeout, :lock_corrupt] do
      deps = %{
        with_lock: fn _fun -> {:error, reason} end,
        process_start: fn ^pid -> {:ok, "self-start"} end
      }

      assert {:error, ^reason} = PendingBundle.claim("obsd", deps)
      refute File.exists?(Home.bundle_dir("obsd") <> ".pending")
    end
  end
end
