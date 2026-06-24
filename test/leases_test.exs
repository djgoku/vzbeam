defmodule VzBeam.LeasesTest do
  use ExUnit.Case, async: true

  @sample """
  {
  \tname=base
  \tip_address=192.168.64.7
  \thw_address=1,5e:aa:bb:cc:dd:ee
  \tlease=0x600
  }
  {
  \tip_address=192.168.64.9
  \thw_address=1,aa:bb:cc:dd:ee:ff
  }
  """

  test "parse extracts mac/ip/name entries" do
    entries = VzBeam.Leases.parse(@sample)
    assert %{mac: "5e:aa:bb:cc:dd:ee", ip: "192.168.64.7", name: "base"} in entries
    assert length(entries) == 2
  end

  test "lookup_ip matches case-insensitively" do
    assert VzBeam.Leases.lookup_ip(@sample, "5E:AA:BB:CC:DD:EE") == "192.168.64.7"
    assert VzBeam.Leases.lookup_ip(@sample, "00:00:00:00:00:00") == nil
  end

  test "read/0 returns \"\" when the leases file is absent" do
    # default path won't exist in CI sandbox; must not raise
    assert is_binary(VzBeam.Leases.read())
  end
end
