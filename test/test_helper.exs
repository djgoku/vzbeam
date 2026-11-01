# Tests tagged :macos shell out to macOS-only tools (plutil, `cp -c` clonefile).
exclude = if :os.type() == {:unix, :darwin}, do: [], else: [:macos]
ExUnit.start(exclude: exclude)
