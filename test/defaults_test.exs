defmodule VzBeam.DefaultsTest do
  use ExUnit.Case, async: true

  test "values has the five defaults" do
    v = VzBeam.Defaults.values()
    assert v.cpu == 4 and v.mem_gb == 8 and v.disk_gb == 64
    assert v.resolution == "1920x1200" and v.ssh_user == "admin"
  end

  test "resolve prefers a non-nil flag over the default" do
    assert VzBeam.Defaults.resolve(8, :cpu) == 8
    assert VzBeam.Defaults.resolve(nil, :cpu) == 4
  end
end
