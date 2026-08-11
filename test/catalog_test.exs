defmodule VzBeam.CatalogTest do
  use ExUnit.Case, async: true
  alias VzBeam.Catalog

  # A trimmed com_apple_macOSIPSW.xml: the VirtualMac2,1 entry (with its
  # "Unknown"/"Universal" duplicate nest, as Apple publishes it) plus a
  # physical Mac whose URL must NOT leak into the result.
  @plist """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>MobileDeviceSoftwareVersionsByVersion</key>
    <dict>
      <key>1</key>
      <dict>
        <key>MobileDeviceSoftwareVersions</key>
        <dict>
          <key>VirtualMac2,1</key>
          <dict>
            <key>25G76</key>
            <dict>
              <key>Restore</key>
              <dict>
                <key>ProductVersion</key><string>26.6.1</string>
                <key>BuildVersion</key><string>25G76</string>
                <key>FirmwareURL</key><string>https://updates.example/UniversalMac_26.6.1_25G76_Restore.ipsw</string>
              </dict>
            </dict>
            <key>Unknown</key>
            <dict>
              <key>Universal</key>
              <dict>
                <key>Restore</key>
                <dict>
                  <key>ProductVersion</key><string>26.6.1</string>
                  <key>BuildVersion</key><string>25G76</string>
                  <key>FirmwareURL</key><string>https://updates.example/UniversalMac_26.6.1_25G76_Restore.ipsw</string>
                </dict>
              </dict>
            </dict>
          </dict>
          <key>Mac14,2</key>
          <dict>
            <key>25G76</key>
            <dict>
              <key>Restore</key>
              <dict>
                <key>ProductVersion</key><string>26.6.1</string>
                <key>BuildVersion</key><string>25G76</string>
                <key>FirmwareURL</key><string>https://updates.example/physical-only.ipsw</string>
              </dict>
            </dict>
          </dict>
        </dict>
      </dict>
    </dict>
  </dict>
  </plist>
  """

  defp deps(plist \\ @plist), do: %{get: fn _url -> {:ok, plist} end}

  test "list extracts the VirtualMac2,1 entries via plutil" do
    assert {:ok, [entry]} = Catalog.list(deps())
    assert entry == %{"version" => "26.6.1", "build" => "25G76",
                      "url" => "https://updates.example/UniversalMac_26.6.1_25G76_Restore.ipsw"}
  end

  test "resolve matches a build id case-insensitively" do
    assert {:ok, %{"build" => "25G76"}} = Catalog.resolve("25g76", deps())
  end

  test "resolve reports a build the catalog does not offer" do
    assert {:error, {:unknown_build, "20G80"}} = Catalog.resolve("20G80", deps())
  end

  test "a fetch failure propagates" do
    assert {:error, :net_down} = Catalog.list(%{get: fn _ -> {:error, :net_down} end})
  end

  test "a non-plist body errors instead of raising" do
    assert {:error, {:plutil_failed, _}} = Catalog.list(deps("not a plist"))
  end

  test "temporary-directory allocation failures propagate" do
    deps = Map.put(deps(), :make_tmp_dir, fn -> {:error, :no_tmp_dir} end)
    assert {:error, :no_tmp_dir} = Catalog.list(deps)
  end

  test "refuses to follow a pre-existing catalog plist symlink" do
    root =
      Path.join(System.tmp_dir!(), "vzbeam-catalog-test-#{System.unique_integer([:positive])}")

    private = Path.join(root, "private")
    target = Path.join(root, "target")
    File.mkdir_p!(private)
    File.write!(target, "keep-me")
    File.ln_s!(target, Path.join(private, "catalog.plist"))
    on_exit(fn -> File.rm_rf!(root) end)

    deps = Map.put(deps(), :make_tmp_dir, fn -> {:ok, private} end)
    assert {:error, :eexist} = Catalog.list(deps)
    assert File.read!(target) == "keep-me"
  end
end
