# Tests tagged :macos shell out to macOS-only tools (plutil, APFS `cp -c`
# clonefile) and can only pass on a Darwin host.
exclude = if match?({:unix, :darwin}, :os.type()), do: [], else: [:macos]
ExUnit.start(exclude: exclude)
