defmodule VzBeam.ApplicationTest do
  use ExUnit.Case, async: true

  test "cli_mode? is false outside a Burrito release (keeps mix test inert)" do
    refute VzBeam.Application.cli_mode?()
  end

  test "the inert supervisor is running under mix test" do
    assert is_pid(Process.whereis(VzBeam.Supervisor))
  end
end
