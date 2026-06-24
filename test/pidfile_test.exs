defmodule VzBeam.PidfileTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "vm"))
    System.put_env("VZBEAM_HOME", home)
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    :ok
  end

  test "process_start succeeds for self, errors for an impossible pid" do
    assert {:ok, _} = VzBeam.Pidfile.process_start(System.pid())
    assert :error = VzBeam.Pidfile.process_start(2_147_483_000)
  end

  test "running? is true right after writing our own pid" do
    :ok = VzBeam.Pidfile.write("vm", System.pid())
    assert VzBeam.Pidfile.running?("vm")
  end

  test "running? is false when startedAt was tampered (PID reuse guard)" do
    :ok = VzBeam.Pidfile.write("vm", System.pid())
    {:ok, m} = VzBeam.Pidfile.read("vm")
    File.write!(VzBeam.Pidfile.path("vm"), Jason.encode!(%{m | "startedAt" => "Bogus Time"}))
    refute VzBeam.Pidfile.running?("vm")
  end

  test "running? is false when there is no pidfile" do
    refute VzBeam.Pidfile.running?("vm")
  end

  test "stores pid as an integer" do
    :ok = VzBeam.Pidfile.write("vm", System.pid())
    {:ok, m} = VzBeam.Pidfile.read("vm")
    assert is_integer(m["pid"])
  end
end
