import VzCore
import Foundation
import Virtualization

var failures = 0
func check(_ name: String, _ cond: Bool) {
    FileHandle.standardError.write(Data(((cond ? "ok: " : "FAIL: ") + name + "\n").utf8))
    if !cond { failures += 1 }
}

// --- Args ---
let a = Args(["run", "--mac", "5e:1", "--headless", "--share", "tag", "/p"],
             booleanFlags: ["headless"], pairFlags: ["share"])
check("args.positional", a.positionals == ["run"])
check("args.value", a.value("mac") == "5e:1")
check("args.bool", a.has("headless"))
check("args.pair.tag", a.pair("share")?.0 == "tag")
check("args.pair.path", a.pair("share")?.1 == "/p")

// --- Wire ---
if let line = Wire.encode(["type": "version", "protocol": 2]) {
    check("wire.singleLine", !line.contains("\n"))
    if let data = line.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        check("wire.type", obj["type"] as? String == "version")
        check("wire.protocol", obj["protocol"] as? Int == 2)
    } else { check("wire.parse", false) }
} else { check("wire.encode", false) }

// --- Wire.errorFields (Error -> domain/code/message mapping) ---
let cfgF = Wire.errorFields(ConfigError.badField("mac"))
check("err.config.domain", cfgF.domain == "vz")
check("err.config.code", cfgF.code == 2)
check("err.config.message", cfgF.message == "invalid mac")

let plainF = Wire.errorFields(NSError(domain: "VZErrorDomain", code: 6,
                                      userInfo: [NSLocalizedDescriptionKey: "max VMs"]))
check("err.framework.domain", plainF.domain == "VZErrorDomain")
check("err.framework.code", plainF.code == 6)
check("err.framework.message", plainF.message == "max VMs")

let underlying = NSError(domain: "com.apple.MobileDevice.MobileRestore", code: 4014,
                         userInfo: [NSLocalizedDescriptionKey: "DFU"])
let wrappedF = Wire.errorFields(NSError(domain: "VZErrorDomain", code: 10007,
                                        userInfo: [NSLocalizedDescriptionKey: "Installation failed.",
                                                   NSUnderlyingErrorKey: underlying]))
check("err.underlying.folds", wrappedF.message.contains("Installation failed.") && wrappedF.message.contains("4014"))

// --- GuestOS / ReID ---
check("guest.macos", (try? GuestOS.parse("macos")) == .macos)
check("guest.openbsd", (try? GuestOS.parse("openbsd")) == .openbsd)
check("guest.missing", (try? GuestOS.parse(nil)) == nil)
check("guest.invalid", (try? GuestOS.parse("linux")) == nil)

let (macMid, mac) = mintIdentity(for: .macos)
check("reid.macos.base64", !macMid.isEmpty && Data(base64Encoded: macMid) != nil)
check("reid.mac.format", mac.range(of: #"^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$"#, options: .regularExpression) != nil)

let (genericMid, _) = mintIdentity(for: .openbsd)
check("reid.openbsd.base64", !genericMid.isEmpty && Data(base64Encoded: genericMid) != nil)
check("reid.identities.differ", genericMid != macMid)

// --- Run parsing / generic EFI configuration ---
let runBase = ["--machine-id", genericMid, "--mac", "5e:11:22:33:44:55",
               "--disk", "/tmp/disk.img", "--cpu", "2", "--mem", "2147483648"]
func rejectsRun(_ args: [String]) -> Bool { (try? parseRunOpts(args)) == nil }
check("run.macos.reject.iso", rejectsRun(runBase + ["--guest", "macos", "--hardware-model", macMid,
                                                        "--aux", "/tmp/aux.img", "--iso", "/tmp/a.iso"]))
check("run.macos.reject.nvram", rejectsRun(runBase + ["--guest", "macos", "--hardware-model", macMid,
                                                           "--aux", "/tmp/aux.img", "--nvram", "/tmp/nvram.bin"]))
check("run.openbsd.reject.hardware", rejectsRun(runBase + ["--guest", "openbsd", "--nvram", "/tmp/nvram.bin",
                                                               "--hardware-model", macMid]))
check("run.openbsd.reject.aux", rejectsRun(runBase + ["--guest", "openbsd", "--nvram", "/tmp/nvram.bin",
                                                          "--aux", "/tmp/aux.img"]))
check("run.openbsd.reject.share", rejectsRun(runBase + ["--guest", "openbsd", "--nvram", "/tmp/nvram.bin",
                                                            "--share", "src", "/tmp"]))

let fm = FileManager.default
let vmDir = fm.temporaryDirectory.appendingPathComponent("vzcheck-\(UUID().uuidString)", isDirectory: true)
let diskURL = vmDir.appendingPathComponent("disk.img")
let isoURL = vmDir.appendingPathComponent("install.iso")
let nvramURL = vmDir.appendingPathComponent("nvram.bin")
try? fm.createDirectory(at: vmDir, withIntermediateDirectories: true)
fm.createFile(atPath: diskURL.path, contents: Data(repeating: 0, count: 1024 * 1024))
fm.createFile(atPath: isoURL.path, contents: Data(repeating: 0, count: 2048))
defer { try? fm.removeItem(at: vmDir) }

do {
    let guiOpts = RunOpts(guest: .openbsd, machineId: genericMid, hardwareModel: nil,
                          mac: "5e:11:22:33:44:55", disk: diskURL.path, aux: nil,
                          nvram: nvramURL.path, iso: isoURL.path, cpu: 2,
                          mem: 2_147_483_648, gui: true, width: 1024, height: 768,
                          share: nil, createNVRAM: true)
    let guiCfg = try buildConfiguration(guiOpts)
    check("efi.platform", guiCfg.platform is VZGenericPlatformConfiguration)
    check("efi.boot", guiCfg.bootLoader is VZEFIBootLoader)
    check("efi.storage.count", guiCfg.storageDevices.count == 2)
    check("efi.storage.iso-first", guiCfg.storageDevices.first is VZUSBMassStorageDeviceConfiguration)
    check("efi.storage.disk-second", guiCfg.storageDevices.last is VZVirtioBlockDeviceConfiguration)
    check("efi.graphics", guiCfg.graphicsDevices.first is VZVirtioGraphicsDeviceConfiguration)
    check("efi.entropy", guiCfg.entropyDevices.first is VZVirtioEntropyDeviceConfiguration)
    check("efi.gui.keyboard", guiCfg.keyboards.first is VZUSBKeyboardConfiguration)
    check("efi.gui.pointer", guiCfg.pointingDevices.first is VZUSBScreenCoordinatePointingDeviceConfiguration)
    check("efi.nvram.created", fm.fileExists(atPath: nvramURL.path))

    let headlessOpts = RunOpts(guest: .openbsd, machineId: genericMid, hardwareModel: nil,
                               mac: "5e:11:22:33:44:55", disk: diskURL.path, aux: nil,
                               nvram: nvramURL.path, iso: nil, cpu: 2,
                               mem: 2_147_483_648, gui: false, width: 1024, height: 768,
                               share: nil, createNVRAM: false)
    let headlessCfg = try buildConfiguration(headlessOpts)
    check("efi.headless.graphics", headlessCfg.graphicsDevices.count == 1)
    check("efi.headless.keyboard", headlessCfg.keyboards.isEmpty)
    check("efi.headless.pointer", headlessCfg.pointingDevices.isEmpty)
} catch {
    FileHandle.standardError.write(Data("FAIL: efi.configuration \(error)\n".utf8))
    failures += 1
}

// --- validateTag (VZVirtioFileSystemDeviceConfiguration) ---
check("tag.valid", (try? VZVirtioFileSystemDeviceConfiguration.validateTag("share")) != nil)
check("tag.empty", (try? VZVirtioFileSystemDeviceConfiguration.validateTag("")) == nil)
check("tag.toolong", (try? VZVirtioFileSystemDeviceConfiguration.validateTag(String(repeating: "a", count: 37))) == nil)

FileHandle.standardError.write(Data((failures == 0 ? "ALL CHECKS PASS\n" : "\(failures) CHECK(S) FAILED\n").utf8))
exit(failures == 0 ? 0 : 1)
