# vzbeam Plan 4 — Swift `vz` sidecar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Swift `vz` sidecar — the only component that links `Virtualization.framework` — implementing `--version`/`reid`/`image-info`/`restore`/`run`, its `mix vz.build` provisioning, and the two engine argv-seam fixes, matching the frozen wire contract byte-for-byte.

**Architecture:** A zero-dependency SwiftPM package (`swift/`) split into a `VzCore` library (all logic, unit-tested with `swift test`) and a thin `vz` executable (argv dispatch). The Elixir engine (Plans 1–3, on `main`) already locates + version-checks + orchestrates it. Green-bucket work (Elixir, `reid`, `image-info` shape, provisioning, the signal mechanism) is developed + validated on the **build host**; boot-dependent work (`restore`, `run` boot) is compile-checked here and behavior-validated on the **Mac** (`dj_goku@10.5.0.48`) over SSH via a documented suite.

**Tech Stack:** Swift 6.x + SwiftPM + Command Line Tools (SDK 26 here / 27 on the Mac), `Virtualization.framework`, `AppKit`; Elixir/escript engine (mise: Elixir 1.20.1 / OTP 29 on the Mac).

**Spec:** `docs/superpowers/specs/2026-06-24-vzbeam-plan4-swift-sidecar.md` (Codex-reviewed, 8 findings folded in).

## Global Constraints

- **Wire discipline:** every machine-readable event is **one compact JSON object per line on stdout** + `\n` + `fflush(stdout)`; **all human logs go to stderr**. Nothing else writes stdout. (spec §4)
- **Protocol version = 1.** `vz --version` → `{"type":"version","protocol":1}`. (spec §6.1)
- **Terminal precedence:** an `{"type":"error"}` event or non-zero exit dominates any prior terminal event. (spec §4)
- **Identity ownership:** Swift mints + emits `machineIdentifier`/`hardwareModel`/`macAddress` (base64 / MAC strings); it never reads or writes config/state files. (spec §4)
- **Zero SwiftPM external dependencies** — link only system frameworks; hand-rolled arg parsing. (spec §3)
- **Re-sign every build** — `swift build` drops the entitlement on each relink, so `mix vz.build` codesigns *after* building. (spec §3, fact #10)
- **Keep `mix test` green** and **independent of a built sidecar** — the default suite uses `test/support/fake_vz`; no default test may require the real `vz`.
- **Per-machine build + sign** — `mix vz.build` runs on the build host *and* the Mac. (spec §2/§10)
- **`swift-tools-version:5.9`** — compiles on both Swift 6.3.2 (here) and 6.4 (Mac); avoids Swift-6 strict-concurrency defaults.
- **Swift green-bucket checks run via `swift run vzcheck`** (a plain assertion-executable target), NOT XCTest/`swift test` — `XCTest.framework` is absent under CLT-only Swift 6.3.2 (validated Task 3, controller decision). Any task below shown with an `XCTest`/`swift test` block instead ADDS its assertions as check-functions to `swift/Sources/vzcheck/main.swift` and verifies with `swift run vzcheck` (no toolset, no flags — portable to the Mac).

---

## File structure

**New (Swift package):**
- `swift/Package.swift` — `VzCore` library + `vz` executable + `VzCoreTests` test target; links Virtualization + AppKit.
- `swift/vz.entitlements` — `com.apple.security.virtualization = true`.
- `swift/Sources/VzCore/{Wire,Args,Version,ReID,ImageInfo,VMConfig,Restore,Run,Entry}.swift` — one responsibility each.
- `swift/Sources/vz/main.swift` — calls `VzCore.dispatch(CommandLine.arguments)`.
- `swift/Tests/VzCoreTests/{ArgsTests,WireTests,ReIDTests,TagTests}.swift` — green-bucket unit tests.

**New (engine):**
- `lib/mix/tasks/vz.build.ex` — the provisioning `Mix.Task`.

**Modified (engine):**
- `lib/vzbeam/commands/run.ex` — `build_argv/5` (seam fix) + the not-found error string.
- `test/commands/run_test.exs` — `make_bundle/1` + the new argv-assertion test.
- `test/support/fake_vz` — `image-info` emits `source` per-arg.

---

## Task 1: Engine seam — `build_argv` identity inputs + explicit disk/aux

**Files:**
- Modify: `lib/vzbeam/commands/run.ex` (`build_argv/5`, lines 153-157)
- Test: `test/commands/run_test.exs` (`make_bundle/1`, lines 15-21; add one test)

**Interfaces:**
- Produces: the post-seam `vz run` argv consumed by Task 9 — `["--machine-id", <b64>, "--hardware-model", <b64>, "--mac", <mac>, "--disk", <bundle>/disk.img, "--aux", <bundle>/aux.img, "--cpu", <n>, "--mem", <bytes>, ("--gui"|"--headless"), "--resolution", <WxH>] (++ ["--share", <tag>, <abspath>])`.

- [ ] **Step 1: Add identity fields to the test bundle fixture**

In `test/commands/run_test.exs`, change `make_bundle/1` to include the identity fields:
```elixir
defp make_bundle(name) do
  dir = Path.join(System.get_env("VZBEAM_HOME"), name)
  File.mkdir_p!(dir)
  File.write!(Path.join(dir, "config.json"),
    Jason.encode!(%{"name" => name, "macAddress" => "5e:aa:bb:cc:dd:ee",
                    "machineIdentifier" => "MID", "hardwareModel" => "HW",
                    "cpuCount" => 2, "memoryBytes" => 2_147_483_648}))
end
```

- [ ] **Step 2: Write the failing argv-contract test**

Add to `test/commands/run_test.exs` (and a small helper at the bottom of the module):
```elixir
test "argv carries identity + explicit disk/aux and drops --bundle" do
  {out, 0} = System.cmd("sh", ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"])
  pid = out |> String.trim() |> String.to_integer()
  on_exit(fn -> System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true) end)
  File.write!(Path.join([System.get_env("VZBEAM_HOME"), "dev", "run.log"]),
    ~s({"type":"started","pid":#{pid}}\n))

  parent = self()
  spawn = fn argv, _log -> send(parent, {:argv, argv}); {:ok, pid} end
  assert {:ok, _} = Run.run(["dev"], deps(spawn))

  assert_received {:argv, argv}
  home = System.get_env("VZBEAM_HOME")
  refute "--bundle" in argv
  assert arg_after(argv, "--machine-id") == "MID"
  assert arg_after(argv, "--hardware-model") == "HW"
  assert arg_after(argv, "--disk") == Path.join([home, "dev", "disk.img"])
  assert arg_after(argv, "--aux") == Path.join([home, "dev", "aux.img"])
  assert arg_after(argv, "--mac") == "5e:aa:bb:cc:dd:ee"
  assert "--headless" in argv
  assert arg_after(argv, "--resolution") == "1920x1200"
end

defp arg_after(argv, flag) do
  case Enum.find_index(argv, &(&1 == flag)) do
    nil -> nil
    i -> Enum.at(argv, i + 1)
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/commands/run_test.exs -n "argv carries identity"` (or run the file)
Expected: FAIL — current `build_argv` emits `--bundle` and omits `--machine-id`/`--disk`/`--aux`.

- [ ] **Step 4: Apply the seam fix to `build_argv/5`**

In `lib/vzbeam/commands/run.ex`, replace `build_argv/5`:
```elixir
defp build_argv(vz, name, m, opts, share) do
  bundle = Home.bundle_dir(name)
  [vz, "run",
   "--machine-id", m["machineIdentifier"], "--hardware-model", m["hardwareModel"], "--mac", m["macAddress"],
   "--disk", Path.join(bundle, "disk.img"), "--aux", Path.join(bundle, "aux.img"),
   "--cpu", to_string(m["cpuCount"]), "--mem", to_string(m["memoryBytes"]),
   mode_flag(opts), "--resolution", Defaults.resolve(opts[:resolution], :resolution)] ++ share_args(share)
end
```

- [ ] **Step 5: Run the full suite to verify green**

Run: `mix test`
Expected: PASS, 101 tests (was 100; +1 new).

- [ ] **Step 6: Commit**

```bash
git add lib/vzbeam/commands/run.ex test/commands/run_test.exs
git commit -m "feat(run): pass identity + explicit disk/aux to vz run (seam fix)"
```

---

## Task 2: Engine — faithful `fake_vz` `source` + provisioning error string

**Files:**
- Modify: `test/support/fake_vz` (line 4)
- Modify: `lib/vzbeam/commands/run.ex` (line 188)

**Interfaces:**
- Produces: the `image-info` `source` contract (`latest`|`local`) the real `vz` matches in Task 6.

- [ ] **Step 1: Make `fake_vz` emit `source` per-arg**

In `test/support/fake_vz`, replace the `image-info)` line so `source` reflects the spec arg:
```sh
  image-info)
    if [ "$2" = "latest" ]; then src=latest; else src=local; fi
    echo "{\"type\":\"image\",\"version\":\"26.5.1\",\"build\":\"25F80\",\"url\":\"file:///x.ipsw\",\"source\":\"$src\"}"
    exit 0 ;;
```

- [ ] **Step 2: Update the not-found error string**

In `lib/vzbeam/commands/run.ex` line 188, change the message:
```elixir
defp error({:error, :not_found}), do: {:error, 1, "run: sidecar not found; build it (`mix vz.build`)\n"}
```

- [ ] **Step 3: Run the full suite**

Run: `mix test`
Expected: PASS, 101 tests. (No test execs `fake_vz` `image-info` via the default runner, and none pins the not-found string — both verified.)

- [ ] **Step 4: Commit**

```bash
git add test/support/fake_vz lib/vzbeam/commands/run.ex
git commit -m "feat: fake_vz emits image-info source per-arg; point not-found at mix vz.build"
```

---

## Task 3: Swift package skeleton + `Wire`/`Args`/`Version` (green-bucket, `swift test`)

**Files:**
- Create: `swift/Package.swift`, `swift/vz.entitlements`
- Create: `swift/Sources/VzCore/{Wire,Args,Version,Entry}.swift`, `swift/Sources/vz/main.swift`
- Test: `swift/Tests/VzCoreTests/{ArgsTests,WireTests}.swift`

**Interfaces:**
- Produces: `VzCore.dispatch(_ args: [String])`; `Wire.emit(_ obj: [String: Any])`, `Wire.log(_ msg: String)`; `Args(_ argv:[String], booleanFlags:Set<String>, pairFlags:Set<String>)` with `.value(_)`, `.has(_)`, `.pair(_)`, `.positionals`.

- [ ] **Step 1: Create `swift/Package.swift`**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "vz",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "VzCore", linkerSettings: [
            .linkedFramework("Virtualization"),
            .linkedFramework("AppKit"),
        ]),
        .executableTarget(name: "vz", dependencies: ["VzCore"]),
        .testTarget(name: "VzCoreTests", dependencies: ["VzCore"]),
    ]
)
```

- [ ] **Step 2: Create `swift/vz.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.virtualization</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 3: Create `swift/Sources/VzCore/Wire.swift`**

```swift
import Foundation

public enum Wire {
    /// One compact JSON line on stdout + newline + flush. Keys sorted for stable output.
    public static func emit(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            log("vz: failed to serialize event"); return
        }
        print(line)        // print adds "\n"
        fflush(stdout)
    }
    public static func log(_ msg: String) {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
    }
}
```

- [ ] **Step 4: Create `swift/Sources/VzCore/Args.swift`**

```swift
import Foundation

/// Tiny flag parser. `--k v` value flags by default; `booleanFlags` take no value;
/// `pairFlags` consume the next TWO args (e.g. `--share <tag> <path>`).
public struct Args {
    public let positionals: [String]
    private let options: [String: String]
    private let flags: Set<String>
    private let pairs: [String: (String, String)]

    public init(_ argv: [String], booleanFlags: Set<String> = [], pairFlags: Set<String> = []) {
        var pos: [String] = []; var opts: [String: String] = [:]
        var flgs: Set<String> = []; var prs: [String: (String, String)] = [:]
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if booleanFlags.contains(key) { flgs.insert(key); i += 1 }
                else if pairFlags.contains(key), i + 2 < argv.count {
                    prs[key] = (argv[i + 1], argv[i + 2]); i += 3
                } else if i + 1 < argv.count { opts[key] = argv[i + 1]; i += 2 }
                else { flgs.insert(key); i += 1 }
            } else { pos.append(a); i += 1 }
        }
        positionals = pos; options = opts; flags = flgs; pairs = prs
    }
    public func value(_ k: String) -> String? { options[k] }
    public func has(_ k: String) -> Bool { flags.contains(k) }
    public func pair(_ k: String) -> (String, String)? { pairs[k] }
}
```

- [ ] **Step 5: Create `swift/Sources/VzCore/Version.swift`**

```swift
public func runVersion() { Wire.emit(["type": "version", "protocol": 1]) }
```

- [ ] **Step 6: Create `swift/Sources/VzCore/Entry.swift` (dispatch skeleton)**

```swift
import Foundation

public func dispatch(_ argv: [String]) {
    let args = Array(argv.dropFirst())   // drop program name
    guard let sub = args.first else { Wire.log("vz: missing subcommand"); exit(2) }
    let rest = Array(args.dropFirst())
    switch sub {
    case "--version": runVersion(); exit(0)
    // reid/image-info/restore/run wired in later tasks:
    default: Wire.log("vz: unknown subcommand \(sub)"); exit(2)
    }
}
```

- [ ] **Step 7: Create `swift/Sources/vz/main.swift`**

```swift
import VzCore
dispatch(CommandLine.arguments)
```

- [ ] **Step 8: Write `swift/Tests/VzCoreTests/ArgsTests.swift`**

```swift
import XCTest
@testable import VzCore

final class ArgsTests: XCTestCase {
    func testValueBooleanPairPositional() {
        let a = Args(["run", "--mac", "5e:1", "--headless", "--share", "tag", "/p"],
                     booleanFlags: ["headless"], pairFlags: ["share"])
        XCTAssertEqual(a.positionals, ["run"])
        XCTAssertEqual(a.value("mac"), "5e:1")
        XCTAssertTrue(a.has("headless"))
        XCTAssertEqual(a.pair("share")?.0, "tag")
        XCTAssertEqual(a.pair("share")?.1, "/p")
    }
}
```

- [ ] **Step 9: Write `swift/Tests/VzCoreTests/WireTests.swift`**

```swift
import XCTest
import Foundation
@testable import VzCore

final class WireTests: XCTestCase {
    func testEmitIsOneCompactJSONLine() throws {
        // Capture stdout via a pipe.
        let pipe = Pipe(); let saved = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        Wire.emit(["type": "version", "protocol": 1])
        fflush(stdout); dup2(saved, STDOUT_FILENO); pipe.fileHandleForWriting.closeFile()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
        XCTAssertEqual(out.filter { $0 == "\n" }.count, 1)              // exactly one line
        let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "version")
        XCTAssertEqual(obj["protocol"] as? Int, 1)
    }
}
```

- [ ] **Step 10: Build + test**

Run: `cd swift && swift build && swift test`
Expected: build succeeds; both tests PASS. Then `swift run vz --version` prints `{"protocol":1,"type":"version"}`.

- [ ] **Step 11: Commit**

```bash
git add swift/
git commit -m "feat(vz): SwiftPM skeleton + Wire/Args/Version with unit tests"
```

---

## Task 4: `mix vz.build` provisioning (green-bucket pipeline proof)

**Files:**
- Create: `lib/mix/tasks/vz.build.ex`

**Interfaces:**
- Produces: a signed `vz` at `$VZBEAM_HOME/bin/vz` discoverable by `VzBeam.Sidecar.locate/0`.

- [ ] **Step 1: Create the Mix task**

```elixir
defmodule Mix.Tasks.Vz.Build do
  use Mix.Task
  @shortdoc "Build, ad-hoc-sign (virtualization entitlement), and install the Swift vz sidecar"
  @swift "swift"

  @impl true
  def run(_argv) do
    Mix.Task.run("compile")
    product = build()
    sign(product)
    dest = install(product)
    Mix.shell().info("vz installed -> #{dest}")
  end

  defp build do
    {_, 0} = System.cmd("swift", ["build", "-c", "release", "--package-path", @swift],
                        stderr_to_stdout: true, into: IO.stream(:stdio, :line))
    {bin, 0} = System.cmd("swift", ["build", "-c", "release", "--package-path", @swift, "--show-bin-path"])
    Path.join(String.trim(bin), "vz")
  end

  defp sign(product) do
    ent = Path.join(@swift, "vz.entitlements")
    {_, 0} = System.cmd("codesign", ["--force", "--sign", "-", "--entitlements", ent, product],
                        stderr_to_stdout: true)
  end

  defp install(product) do
    bin = Path.join(VzBeam.Home.root(), "bin")
    File.mkdir_p!(bin)
    dest = Path.join(bin, "vz")
    File.cp!(product, dest)
    File.chmod!(dest, 0o755)
    dest
  end
end
```

- [ ] **Step 2: Verify the provisioning pipeline end-to-end (green-bucket)**

Run:
```bash
export VZBEAM_HOME="$(mktemp -d)/vzhome"
mix vz.build
"$VZBEAM_HOME/bin/vz" --version
```
Expected: build + sign succeed; last line prints `{"protocol":1,"type":"version"}`.

- [ ] **Step 3: Verify the engine locates + version-checks it**

Run: `VZBEAM_HOME="$VZBEAM_HOME" mix run -e 'IO.inspect(VzBeam.Sidecar.check_version())'`
Expected: `:ok`.

- [ ] **Step 4: Verify the entitlement embedded**

Run: `codesign -d --entitlements - "$VZBEAM_HOME/bin/vz" 2>&1 | grep virtualization`
Expected: shows `com.apple.security.virtualization`.

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/vz.build.ex
git commit -m "feat: mix vz.build provisioning (swift build + ad-hoc codesign + install)"
```

---

## Task 5: `reid` (green-bucket)

**Files:**
- Create: `swift/Sources/VzCore/ReID.swift`
- Modify: `swift/Sources/VzCore/Entry.swift` (add `case "reid"`)
- Test: `swift/Tests/VzCoreTests/ReIDTests.swift`

**Interfaces:**
- Consumes: `Wire.emit`.
- Produces: `mintIdentity() -> (machineId: String, mac: String)`; `runReid()`.

- [ ] **Step 1: Write the failing test**

`swift/Tests/VzCoreTests/ReIDTests.swift`:
```swift
import XCTest
import Foundation
@testable import VzCore

final class ReIDTests: XCTestCase {
    func testMintIdentity() {
        let (mid, mac) = mintIdentity()
        XCTAssertNotNil(Data(base64Encoded: mid))   // valid base64
        XCTAssertFalse(mid.isEmpty)
        XCTAssertNotNil(mac.range(of: #"^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$"#, options: .regularExpression))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd swift && swift test`
Expected: FAIL — `mintIdentity` undefined.

- [ ] **Step 3: Implement `ReID.swift`**

```swift
import Virtualization
import Foundation

public func mintIdentity() -> (machineId: String, mac: String) {
    (VZMacMachineIdentifier().dataRepresentation.base64EncodedString(),
     VZMACAddress.randomLocallyAdministered().string)
}

public func runReid() {
    let (mid, mac) = mintIdentity()
    Wire.emit(["type": "reid", "machineIdentifier": mid, "macAddress": mac])
}
```

- [ ] **Step 4: Wire into dispatch**

In `Entry.swift`, add before `default:`: `case "reid": runReid(); exit(0)`

- [ ] **Step 5: Run to verify it passes**

Run: `cd swift && swift test`
Expected: PASS.

- [ ] **Step 6: Cross-check through the engine**

Run: `mix vz.build && VZBEAM_HOME="$VZBEAM_HOME" mix run -e 'IO.inspect(VzBeam.Sidecar.reid())'`
Expected: `{:ok, %{machine_identifier: <b64>, mac_address: "..:.."}}` (non-nil fields).

- [ ] **Step 7: Commit**

```bash
git add swift/Sources/VzCore/ReID.swift swift/Sources/VzCore/Entry.swift swift/Tests/VzCoreTests/ReIDTests.swift
git commit -m "feat(vz): reid mints machine identifier + MAC"
```

---

## Task 6: `image-info` (green-bucket shape + error path)

**Files:**
- Create: `swift/Sources/VzCore/ImageInfo.swift`
- Modify: `swift/Sources/VzCore/Entry.swift` (add `case "image-info"`)

**Interfaces:**
- Consumes: `Args`, `Wire`.
- Produces: `runImageInfo(_ args: [String])` — emits an `image` or `error` event, then `exit()`.

- [ ] **Step 1: Implement `ImageInfo.swift`**

```swift
import Virtualization
import Foundation

public func runImageInfo(_ args: [String]) {
    let a = Args(args)
    guard let spec = a.positionals.first else {
        Wire.emit(["type": "error", "domain": "vz", "code": 2, "message": "image-info needs <latest|PATH>"])
        exit(2)
    }
    if spec == "latest" {
        VZMacOSRestoreImage.fetchLatestSupported { result in finishImageInfo(result, source: "latest") }
    } else {
        VZMacOSRestoreImage.load(from: URL(fileURLWithPath: spec)) { result in
            finishImageInfo(result, source: "local")
        }
    }
    RunLoop.main.run()   // handler calls exit(); never returns normally
}

private func finishImageInfo(_ result: Result<VZMacOSRestoreImage, Error>, source: String) {
    // Codex NICE #8: log which queue the handler fired on (validation probe).
    Wire.log("image-info handler on \(Thread.isMainThread ? "main" : "background") thread")
    switch result {
    case .success(let image):
        let v = image.operatingSystemVersion
        Wire.emit([
            "type": "image",
            "version": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            "build": image.buildVersion,
            "url": image.url.absoluteString,
            "source": source,
        ])
        exit(0)
    case .failure(let e):
        Wire.emit(["type": "error", "domain": "VZErrorDomain", "code": (e as NSError).code,
                   "message": e.localizedDescription])
        exit(1)
    }
}
```

- [ ] **Step 2: Wire into dispatch**

In `Entry.swift`, add: `case "image-info": runImageInfo(rest)` (no trailing `exit` — it manages its own).

- [ ] **Step 3: Build**

Run: `cd swift && swift build`
Expected: compiles.

- [ ] **Step 4: Verify the error path + flush-before-exit (green-bucket)**

Run:
```bash
mix vz.build
"$VZBEAM_HOME/bin/vz" image-info /no/such/file.ipsw; echo "exit=$?"
```
Expected: stdout shows one `{"type":"error",...}` line (flushed before exit); stderr shows the handler-thread probe; `exit=1`. (Happy path with a real IPSW is validated on the Mac — Task 11.)

- [ ] **Step 5: Commit**

```bash
git add swift/Sources/VzCore/ImageInfo.swift swift/Sources/VzCore/Entry.swift
git commit -m "feat(vz): image-info (load/latest) with error path + queue probe"
```

---

## Task 7: `VMConfig` builder + `validateTag` (green-bucket tag rules; config compile-checked)

**Files:**
- Create: `swift/Sources/VzCore/VMConfig.swift`
- Test: `swift/Tests/VzCoreTests/TagTests.swift`

**Interfaces:**
- Consumes: nothing engine-side.
- Produces: `struct RunOpts`; `buildConfiguration(_ o: RunOpts) throws -> VZVirtualMachineConfiguration`. Used by Task 9.

- [ ] **Step 1: Write the failing tag-rules test**

`swift/Tests/VzCoreTests/TagTests.swift`:
```swift
import XCTest
import Virtualization
@testable import VzCore

final class TagTests: XCTestCase {
    func testValidateTag() {
        XCTAssertNoThrow(try VZVirtioFileSystemDeviceConfiguration.validateTag("share"))
        XCTAssertThrowsError(try VZVirtioFileSystemDeviceConfiguration.validateTag(""))
        XCTAssertThrowsError(try VZVirtioFileSystemDeviceConfiguration.validateTag(String(repeating: "a", count: 37)))
    }
}
```

- [ ] **Step 2: Run to verify it passes (this API is system-provided)**

Run: `cd swift && swift test`
Expected: PASS (this pins the documented ≤36-byte/non-empty rules on this SDK).

- [ ] **Step 3: Implement `VMConfig.swift`**

```swift
import Virtualization
import Foundation

public struct RunOpts {
    public let machineId: String, hardwareModel: String, mac: String
    public let disk: String, aux: String
    public let cpu: Int, mem: UInt64
    public let gui: Bool, width: Int, height: Int
    public let share: (tag: String, path: String)?
}

public enum ConfigError: Error, CustomStringConvertible {
    case badField(String)
    public var description: String { switch self { case .badField(let f): return "invalid \(f)" } }
}

public func buildConfiguration(_ o: RunOpts) throws -> VZVirtualMachineConfiguration {
    guard let hwData = Data(base64Encoded: o.hardwareModel),
          let hw = VZMacHardwareModel(dataRepresentation: hwData) else { throw ConfigError.badField("hardware-model") }
    guard let idData = Data(base64Encoded: o.machineId),
          let mid = VZMacMachineIdentifier(dataRepresentation: idData) else { throw ConfigError.badField("machine-id") }
    guard let mac = VZMACAddress(string: o.mac) else { throw ConfigError.badField("mac") }

    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel = hw
    platform.machineIdentifier = mid
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: URL(fileURLWithPath: o.aux))

    let cfg = VZVirtualMachineConfiguration()
    cfg.platform = platform
    cfg.bootLoader = VZMacOSBootLoader()
    cfg.cpuCount = o.cpu
    cfg.memorySize = o.mem

    let disk = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: o.disk), readOnly: false)
    cfg.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

    let net = VZVirtioNetworkDeviceConfiguration()
    net.attachment = VZNATNetworkDeviceAttachment()
    net.macAddress = mac
    cfg.networkDevices = [net]

    let gfx = VZMacGraphicsDeviceConfiguration()
    gfx.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: o.width, heightInPixels: o.height, pixelsPerInch: 80)]
    cfg.graphicsDevices = [gfx]   // attached even headless (fact #3)

    if let s = o.share {
        try VZVirtioFileSystemDeviceConfiguration.validateTag(s.tag)
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: s.tag)
        fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(fileURLWithPath: s.path), readOnly: false))
        cfg.directorySharingDevices = [fs]
    }
    if o.gui {
        cfg.keyboards = [VZUSBKeyboardConfiguration()]
        cfg.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    try cfg.validate()
    return cfg
}
```

- [ ] **Step 4: Build (compile-check)**

Run: `cd swift && swift build && swift test`
Expected: compiles; tag test still PASS. (Full `cfg.validate()` success with a *real* hardwareModel is validated on the Mac — here we have no real model bytes to feed it.)

- [ ] **Step 5: Commit**

```bash
git add swift/Sources/VzCore/VMConfig.swift swift/Tests/VzCoreTests/TagTests.swift
git commit -m "feat(vz): VM configuration builder + validated share-tag rules"
```

---

## Task 8: `restore` (HW-gated; compile-checked here, behavior on the Mac)

**Files:**
- Create: `swift/Sources/VzCore/Restore.swift`
- Modify: `swift/Sources/VzCore/Entry.swift` (add `case "restore"`)

**Interfaces:**
- Consumes: `Args`, `Wire`.
- Produces: `runRestore(_ args: [String])` — streams `progress`, then `restored` (or `error`).

- [ ] **Step 1: Implement `Restore.swift`**

```swift
import Virtualization
import Foundation

public func runRestore(_ args: [String]) { RestoreSession(args).start() }

final class RestoreSession {
    private let a: Args
    private var vm: VZVirtualMachine?
    private var installer: VZMacOSInstaller?
    private var obs: NSKeyValueObservation?

    init(_ args: [String]) { self.a = Args(args) }

    func start() {
        guard let ipsw = a.value("ipsw"), let disk = a.value("disk"), let aux = a.value("aux"),
              let cpu = a.value("cpu").flatMap(Int.init), let mem = a.value("mem").flatMap(UInt64.init) else {
            return fail(domain: "vz", code: 2, "restore: missing required flags")
        }
        let diskSize = a.value("disk-size").flatMap(UInt64.init)
        let ipswURL = URL(fileURLWithPath: ipsw)
        VZMacOSRestoreImage.load(from: ipswURL) { [weak self] result in
            switch result {
            case .failure(let e): self?.fail(domain: "VZErrorDomain", code: (e as NSError).code, e.localizedDescription)
            case .success(let image): self?.install(image, ipswURL, disk, aux, diskSize, cpu, mem)
            }
        }
        RunLoop.main.run()
    }

    private func install(_ image: VZMacOSRestoreImage, _ ipswURL: URL, _ disk: String, _ aux: String,
                         _ diskSize: UInt64?, _ cpu: Int, _ mem: UInt64) {
        guard let req = image.mostFeaturefulSupportedConfiguration else {
            return fail(domain: "VZErrorDomain", code: -1, "host does not support this restore image")
        }
        if let want = diskSize, let attrs = try? FileManager.default.attributesOfItem(atPath: disk),
           let have = (attrs[.size] as? NSNumber)?.uint64Value, have != want {
            return fail(domain: "vz", code: 1, "disk.img size \(have) != expected \(want)")  // verify-only (Codex #7)
        }
        let hw = req.hardwareModel
        let mid = VZMacMachineIdentifier()
        let mac = VZMACAddress.randomLocallyAdministered()
        let auxStorage: VZMacAuxiliaryStorage
        do { auxStorage = try VZMacAuxiliaryStorage(creatingStorageAt: URL(fileURLWithPath: aux), hardwareModel: hw, options: []) }
        catch { return fail(domain: "VZErrorDomain", code: (error as NSError).code, "aux create failed: \(error.localizedDescription)") }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hw; platform.machineIdentifier = mid; platform.auxiliaryStorage = auxStorage
        let cfg = VZVirtualMachineConfiguration()
        cfg.platform = platform; cfg.bootLoader = VZMacOSBootLoader()
        cfg.cpuCount = max(cpu, req.minimumSupportedCPUCount)
        cfg.memorySize = max(mem, req.minimumSupportedMemorySize)
        do {
            let d = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: disk), readOnly: false)
            cfg.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: d)]
            try cfg.validate()
        } catch { return fail(domain: "VZErrorDomain", code: (error as NSError).code, error.localizedDescription) }

        let vm = VZVirtualMachine(configuration: cfg); self.vm = vm
        let inst = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipswURL); self.installer = inst
        obs = inst.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
            Wire.emit(["type": "progress", "fraction": p.fractionCompleted])
        }
        let v = image.operatingSystemVersion
        inst.install { [weak self] result in
            self?.obs = nil
            switch result {
            case .success:
                Wire.emit([
                    "type": "restored",
                    "machineIdentifier": mid.dataRepresentation.base64EncodedString(),
                    "hardwareModel": hw.dataRepresentation.base64EncodedString(),
                    "macAddress": mac.string,
                    "version": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                    "build": image.buildVersion,
                ]); exit(0)
            case .failure(let e):
                self?.fail(domain: "VZErrorDomain", code: (e as NSError).code, e.localizedDescription)
            }
        }
    }

    private func fail(domain: String, code: Int, _ message: String) {
        Wire.emit(["type": "error", "domain": domain, "code": code, "message": message]); exit(1)
    }
}
```

- [ ] **Step 2: Wire into dispatch**

In `Entry.swift`, add: `case "restore": runRestore(rest)`

- [ ] **Step 3: Build (compile-check; boot validated on the Mac)**

Run: `cd swift && swift build`
Expected: compiles. (No `restore` boot here — `kern.hv_support=0`. Behavior is Task 11 step 4.)

- [ ] **Step 4: Commit**

```bash
git add swift/Sources/VzCore/Restore.swift swift/Sources/VzCore/Entry.swift
git commit -m "feat(vz): restore (VZMacOSInstaller) with capability gate + progress streaming"
```

---

## Task 9: `run` (HW-gated; the riskiest piece — Codex review before merge)

**Files:**
- Create: `swift/Sources/VzCore/Run.swift`
- Modify: `swift/Sources/VzCore/Entry.swift` (add `case "run"` + the test-only `__sigprobe`)

**Interfaces:**
- Consumes: `buildConfiguration(_:)` (Task 7), `Args`, `Wire`.
- Produces: `runRun(_ args: [String])`; the test-only `runSigProbe()`.

- [ ] **Step 1: Implement `Run.swift`**

```swift
import Virtualization
import AppKit
import Foundation

public func runRun(_ args: [String]) {
    setsid()   // in-process, no fork: getpid() stays == the launch pid the engine captured (Codex #5)
    let a = Args(args, booleanFlags: ["gui", "headless"], pairFlags: ["share"])
    guard let mid = a.value("machine-id"), let hw = a.value("hardware-model"), let mac = a.value("mac"),
          let disk = a.value("disk"), let aux = a.value("aux"),
          let cpu = a.value("cpu").flatMap(Int.init), let mem = a.value("mem").flatMap(UInt64.init) else {
        Wire.emit(["type": "error", "domain": "vz", "code": 2, "message": "run: missing required flags"]); exit(2)
    }
    let (w, h) = parseResolution(a.value("resolution") ?? "1920x1200")
    let share = a.pair("share").map { (tag: $0.0, path: $0.1) }
    let opts = RunOpts(machineId: mid, hardwareModel: hw, mac: mac, disk: disk, aux: aux,
                       cpu: cpu, mem: mem, gui: a.has("gui"), width: w, height: h, share: share)
    RunSession(opts: opts).start()
}

private func parseResolution(_ s: String) -> (Int, Int) {
    let parts = s.lowercased().split(separator: "x")
    if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) { return (w, h) }
    return (1920, 1200)
}

final class RunSession: NSObject, VZVirtualMachineDelegate {
    private let opts: RunOpts
    private var vm: VZVirtualMachine?
    private var finished = false           // only touched on .main → no lock needed
    private var sig: DispatchSourceSignal?

    init(opts: RunOpts) { self.opts = opts }

    func start() {
        let cfg: VZVirtualMachineConfiguration
        do { cfg = try buildConfiguration(opts) }
        catch { return finishError(domain: "VZErrorDomain", code: (error as NSError).code, "\(error)") }

        let vm = VZVirtualMachine(configuration: cfg)   // main queue
        vm.delegate = self; self.vm = vm
        installSignalTrap()
        vm.start { [weak self] result in
            switch result {
            case .success: Wire.emit(["type": "started", "pid": Int(getpid())])
            case .failure(let e):
                self?.finishError(domain: (e as NSError).domain, code: (e as NSError).code, e.localizedDescription)
            }
        }
        if opts.gui { runGUI(vm: vm) } else { RunLoop.main.run() }
    }

    private func installSignalTrap() {
        signal(SIGTERM, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        s.setEventHandler { [weak self] in self?.vm?.stop { _ in self?.finishStopped() } ?? self!.finishStopped() }
        s.resume(); sig = s
    }

    // VZVirtualMachineDelegate (fires on the main queue)
    func guestDidStop(_ virtualMachine: VZVirtualMachine) { finishStopped() }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
        finishError(domain: (error as NSError).domain, code: (error as NSError).code, error.localizedDescription)
    }

    // Single terminal-emission path (Codex BLOCKING #1) — idempotent, main-thread only.
    private func finishStopped() { finishOnce { Wire.emit(["type": "guest_stopped"]); exit(0) } }
    private func finishError(domain: String, code: Int, _ message: String) {
        finishOnce { Wire.emit(["type": "error", "domain": domain, "code": code, "message": message]); exit(1) }
    }
    private func finishOnce(_ body: () -> Void) {
        if finished { return }; finished = true; body()
    }

    private func runGUI(vm: VZVirtualMachine) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let view = VZVirtualMachineView(); view.virtualMachine = vm
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(opts.width / 2, 640), height: max(opts.height / 2, 400)),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "vzbeam"; win.contentView = view
        win.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        app.run()
    }
}

/// Test-only: exercises the SIGTERM→finishOnce→emit-once mechanism under RunLoop.main.run() with no VM.
public func runSigProbe() {
    var finished = false
    signal(SIGTERM, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    s.setEventHandler { if finished { return }; finished = true; Wire.emit(["type": "guest_stopped"]); exit(0) }
    s.resume()
    Wire.emit(["type": "started", "pid": Int(getpid())])
    RunLoop.main.run()
}
```

- [ ] **Step 2: Wire into dispatch**

In `Entry.swift`, add: `case "run": runRun(rest)` and `case "__sigprobe": runSigProbe()`

- [ ] **Step 3: Build (compile-check)**

Run: `cd swift && swift build && swift test`
Expected: compiles; all unit tests still PASS.

- [ ] **Step 4: Green-bucket-validate the signal + finishOnce mechanism (no VM)**

Run:
```bash
mix vz.build
"$VZBEAM_HOME/bin/vz" __sigprobe >/tmp/sig.out 2>/dev/null &
P=$!; sleep 1; kill -TERM "$P"; wait "$P"; echo "exit=$?"; cat /tmp/sig.out
```
Expected: `/tmp/sig.out` contains exactly `{"pid":...,"type":"started"}` then `{"type":"guest_stopped"}` (one each); `exit=0`. This proves fact #2/#9 mechanics + the single-emission guard on this box.

- [ ] **Step 5: Codex review of the run lifecycle before merge**

Per the spec, hand `swift/Sources/VzCore/Run.swift` (+ `VMConfig.swift`) to Codex for an adversarial review of the boot/signal/lifecycle path. Fold findings in. (Driven from the parent session via the codex review flow.)

- [ ] **Step 6: Commit**

```bash
git add swift/Sources/VzCore/Run.swift swift/Sources/VzCore/Entry.swift
git commit -m "feat(vz): run lifecycle (config, single finishOnce terminal path, SIGTERM trap, gui/headless)"
```

---

## Task 10: Build-host green-bucket validation roundup

**Files:** none (verification only).

- [ ] **Step 1: Full engine suite**

Run: `mix test`
Expected: PASS, 101 tests, no warnings.

- [ ] **Step 2: Swift unit tests**

Run: `cd swift && swift test`
Expected: PASS (Args, Wire, ReID, Tag).

- [ ] **Step 3: Provisioning + green-bucket subcommand smokes**

Run (fresh `$VZBEAM_HOME`): `mix vz.build` → `vz --version` (`:ok` via `check_version`), `vz reid` (engine parses), `vz image-info /no/such.ipsw` (error+exit1), `vz __sigprobe` SIGTERM smoke (Task 9 step 4).
Expected: all as specified above.

- [ ] **Step 4: Escript end-to-end against the fake (regression)**

Run: `mix escript.build && VZBEAM_VZ=test/support/fake_vz ./vzbeam ...` the create→ls→run→kill→cap-at-3rd flow.
Expected: unchanged from Plan 3 (the seam edits didn't regress the fake path).

- [ ] **Step 5: Commit a green-bucket evidence note**

```bash
git add docs/superpowers/plans/2026-06-24-vzbeam-swift-sidecar.md
git commit -m "docs: green-bucket validation evidence captured" --allow-empty
```

---

## Task 11: HW-gated Mac integration suite (over SSH; documented results)

**Files:**
- Create: `docs/superpowers/results/2026-06-24-vzbeam-plan4-mac-suite.md` (results log)

**This task is a documented manual/SSH suite, not TDD.** Run from the parent session over `ssh dj_goku@10.5.0.48`. Capture each step's output into the results doc. Order de-risks the A18/Mac17,5 capability first.

- [ ] **Step 1: Sync the tree to the Mac**

Run: `rsync -a --delete --exclude _build --exclude .git --exclude 'swift/.build' ./ dj_goku@10.5.0.48:~/vzbeam/`
Then on the Mac: `cd ~/vzbeam && mise exec -- mix deps.get` (fresh build for OTP 29).

- [ ] **Step 2: Build the sidecar on the Mac**

Run (Mac): `mise exec -- mix vz.build` → `"$VZBEAM_HOME/bin/vz" --version`.
Expected: build+sign succeed; `{"protocol":1,"type":"version"}`. Record Swift version + SDK.

- [ ] **Step 3: `image-info` on the Mac**

Run (Mac): `vz image-info <local IPSW>` (and `vz image-info latest` if network permits).
Expected: an `image` event with real version/build/url; record whether `latest` (catalog) is reachable.

- [ ] **Step 4: `restore` — the capability moment**

Run (Mac): `mise exec -- ./vzbeam fetch <IPSW>` then `mise exec -- ./vzbeam new base --image <latest|PATH>`.
Expected: `progress` events then `restored`; a base bundle with identity. **If `mostFeaturefulSupportedConfiguration` is nil → host can't support macOS guests; stop and report (fall back per spec §2).**

- [ ] **Step 5: First boot + Setup Assistant (⚠️ manual GUI checkpoint)**

Run (Mac): `mise exec -- ./vzbeam run base --gui`. **Hands-on-Mac:** complete Setup Assistant (create `admin`, enable Remote Login), then run the printed one-time `ssh-copy-id`.
Expected: a detached `VZVirtualMachineView` window appears; `started{pid}` in `run.log`; `vm.pid` written; `started.pid == vm.pid` (no-fork invariant, Codex #5).

- [ ] **Step 6: Clone + headless run + reachability**

Run (Mac): `./vzbeam new dev base` → `./vzbeam run dev` (headless) → `./vzbeam ip dev` → `./vzbeam ssh dev -- uname -a`.
Expected: clone has fresh identity; `bridge100` appears; lease resolves; SSH answers (headless `RunLoop.main.run()` networking works).

- [ ] **Step 7: virtiofs share round-trip**

Run (Mac): `./vzbeam run dev --share work=/tmp/share` then in-guest `mount_virtiofs work /Volumes/work` and read/write a file both directions.
Expected: bidirectional file visibility.

- [ ] **Step 8: stop + kill (single terminal event)**

Run (Mac): `./vzbeam stop dev` (graceful: guest `shutdown -h now` → `guestDidStop` → exit0); `./vzbeam run dev` again then `./vzbeam kill dev` (SIGTERM → `vm.stop()` → exit0).
Expected: each leaves **exactly one** `guest_stopped` in `run.log` and exits 0 (the `finishOnce` guard).

- [ ] **Step 9: 2-VM cap — both checks (Codex BLOCKING #2)**

Run (Mac):
- (a) **Pre-check:** with `base` + `dev` running, `./vzbeam run <third>` → "at capacity", **no sidecar spawned**.
- (b) **Framework `VZError 6`:** with two VMs running, invoke the sidecar directly, bypassing the engine — `"$VZBEAM_HOME/bin/vz" run --machine-id … --hardware-model … --mac … --disk …/disk.img --aux …/aux.img --cpu 4 --mem 8589934592 --headless --resolution 1920x1200` against a third bundle.
Expected: (a) the engine error; (b) an `{"type":"error","domain":"VZErrorDomain","code":6,...}` event from `start()`.

- [ ] **Step 10: Cleanup + record results**

Run (Mac): `./vzbeam kill …` any running; `./vzbeam rm …` all bundles.
Write all observed outputs into `docs/superpowers/results/2026-06-24-vzbeam-plan4-mac-suite.md`; commit.

```bash
git add docs/superpowers/results/2026-06-24-vzbeam-plan4-mac-suite.md
git commit -m "docs: Plan 4 Mac integration suite results"
```

---

## Self-Review

**1. Spec coverage:**
- §3 package layout + provisioning → Tasks 3, 4 (refined to `VzCore` lib + `vz` exe for `swift test`; spec's focused-files intent preserved).
- §4 wire discipline + argv → `Wire` (Task 3), seam argv (Task 1), per-subcommand emits (Tasks 5-9).
- §5 seams + 100-green → Tasks 1, 2 (101 green).
- §6.1-6.5 subcommands → Tasks 3 (version), 5 (reid), 6 (image-info), 8 (restore), 7+9 (run/config).
- §6.3 `source` + faithful fake → Tasks 2, 6.
- §6.5 finishOnce, no-fork pid, SIGTERM trap → Task 9 (+ green-bucket probe step 4).
- §7 validation split → Task 10 (green) + Task 11 (Mac suite, incl. cap split 9, single-terminal 8, capability 4).
- §8 testing → Tasks 3/5/7 (swift test), 1/2 (Elixir lockstep), 11 (integration).
- §6.4 `--disk-size` verify-only → Task 8.
- NICE #8 async-queue/flush probe → Task 6 step 4 + the `image-info` handler log.

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; every run step shows expected output. HW-gated Swift (Tasks 8-9) is complete code with explicit compile-check-here / behavior-on-Mac steps.

**3. Type consistency:** `RunOpts` (Task 7) ← `buildConfiguration` ← `RunSession` (Task 9) use the same fields; `mintIdentity()` (Task 5) returns `(machineId, mac)` used by `runReid`; `Wire.emit([String: Any])` signature consistent across all tasks; `Args(_, booleanFlags:, pairFlags:)` consistent (Task 3 def ↔ Task 9 use with `["gui","headless"]`/`["share"]`); argv produced by Task 1 matches what Task 9's `runRun` parses.
