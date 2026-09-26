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

let unsupportedF = Wire.errorFields(ConfigError.unsupported("OpenBSD recovery requires macOS 15 or newer"))
check("err.unsupported.message", unsupportedF.message == "OpenBSD recovery requires macOS 15 or newer")

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
if let recovery = try? parseRunOpts(runBase + ["--guest", "openbsd",
                                               "--nvram", "/tmp/nvram.bin",
                                               "--iso", "/tmp/recovery.iso"]) {
    check("run.openbsd.recovery", recovery.recovery)
} else {
    check("run.openbsd.recovery", false)
}
let namedRun = try? parseRunOpts(runBase + ["--guest", "openbsd", "--nvram", "/tmp/nvram.bin",
                                               "--name", "obsd"])
check("run.name", namedRun?.name == "obsd")
check("run.name.absent", (try? parseRunOpts(runBase + ["--guest", "openbsd", "--nvram", "/tmp/nvram.bin"]))?.name == nil)

// --- Window title ---
check("title.named", vmWindowTitle("vzbeam", name: "obsd") == "obsd — vzbeam")
check("title.unnamed", vmWindowTitle("vzbeam OpenBSD installer", name: nil) == "vzbeam OpenBSD installer")

// --- Install parsing ---
let installArgs = ["--guest", "openbsd", "--iso", "/tmp/install.iso",
                   "--disk", "/tmp/install-disk.img", "--nvram", "/tmp/install-nvram.bin",
                   "--cpu", "2", "--mem", "2147483648", "--resolution", "1024x768",
                   "--parent-pid", String(getpid())]
if let install = try? parseInstallOpts(installArgs) {
    check("install.guest", install.guest == .openbsd)
    check("install.iso", install.iso == "/tmp/install.iso")
    check("install.disk", install.disk == "/tmp/install-disk.img")
    check("install.nvram", install.nvram == "/tmp/install-nvram.bin")
    check("install.dimensions", install.width == 1024 && install.height == 768)
    check("install.parent", install.parentPID == getpid())
    check("install.name.absent", install.name == nil)

    let installRun = RunOpts(guest: install.guest, machineId: genericMid, hardwareModel: nil,
                             mac: "5e:11:22:33:44:55", disk: install.disk, aux: nil,
                             nvram: install.nvram, iso: install.iso, cpu: install.cpu,
                             mem: install.mem, gui: true, width: install.width,
                             height: install.height, share: nil, createNVRAM: true)
    check("install.run.iso", installRun.iso == install.iso)
    check("install.run.creates-nvram", installRun.createNVRAM)
} else {
    check("install.valid", false)
}

func rejectsInstall(_ args: [String]) -> Bool { (try? parseInstallOpts(args)) == nil }
check("install.name", (try? parseInstallOpts(installArgs + ["--name", "obsd"]))?.name == "obsd")
check("install.reject.missing-iso", rejectsInstall(installArgs.filter { $0 != "--iso" && $0 != "/tmp/install.iso" }))
check("install.reject.macos", rejectsInstall(installArgs.map { $0 == "openbsd" ? "macos" : $0 }))
check("install.reject.missing-nvram", rejectsInstall(installArgs.filter { $0 != "--nvram" && $0 != "/tmp/install-nvram.bin" }))
check("install.reject.zero-parent", rejectsInstall(installArgs.dropLast(1) + ["0"]))
check("install.reject.bad-parent", rejectsInstall(installArgs.dropLast(1) + ["not-a-pid"]))

let fm = FileManager.default
let vmDir = fm.temporaryDirectory.appendingPathComponent("vzcheck-\(UUID().uuidString)", isDirectory: true)
let diskURL = vmDir.appendingPathComponent("disk.img")
let isoURL = vmDir.appendingPathComponent("install.iso")
let nvramURL = vmDir.appendingPathComponent("nvram.bin")
let persistentNVRAMURL = vmDir.appendingPathComponent("persistent-nvram.bin")
try? fm.createDirectory(at: vmDir, withIntermediateDirectories: true)
fm.createFile(atPath: diskURL.path, contents: Data(repeating: 0, count: 1024 * 1024))
fm.createFile(atPath: isoURL.path, contents: Data(repeating: 0, count: 2048))
let persistentNVRAM = Data("persistent bundle nvram".utf8)
fm.createFile(atPath: persistentNVRAMURL.path, contents: persistentNVRAM)
defer { try? fm.removeItem(at: vmDir) }

do {
    let recoveryOpts = RunOpts(guest: .openbsd, machineId: genericMid, hardwareModel: nil,
                               mac: "5e:11:22:33:44:55", disk: diskURL.path, aux: nil,
                               nvram: persistentNVRAMURL.path, iso: isoURL.path, cpu: 2,
                               mem: 2_147_483_648, gui: true, width: 1024, height: 768,
                               share: nil, createNVRAM: false, recovery: true)
    let recovery = try prepareRunOptions(recoveryOpts, temporaryRoot: vmDir)
    let temporaryNVRAM = recovery.options.nvram ?? ""
    check("recovery.nvram.temporary", temporaryNVRAM != persistentNVRAMURL.path)
    check("recovery.nvram.creates", recovery.options.createNVRAM)
    check("recovery.nvram.directory", recovery.temporaryDirectory != nil)
    let recoveryCfg = try buildConfiguration(recovery.options)
    check("recovery.storage.iso-usb",
          recoveryCfg.storageDevices.first is VZUSBMassStorageDeviceConfiguration)
    check("recovery.storage.iso-only", recoveryCfg.storageDevices.count == 1)
    if #available(macOS 15.0, *) {
        check("recovery.usb.hotplug-controller",
              recoveryCfg.usbControllers.first is VZXHCIControllerConfiguration)
    } else {
        check("recovery.usb.hotplug-controller", false)
    }
    check("recovery.nvram.temp-created", fm.fileExists(atPath: temporaryNVRAM))
    check("recovery.nvram.bundle-unchanged",
          (try? Data(contentsOf: persistentNVRAMURL)) == persistentNVRAM)
    cleanupRunPreparation(recovery)
    check("recovery.nvram.cleaned", !fm.fileExists(atPath: temporaryNVRAM))

    let normalOpts = RunOpts(guest: .openbsd, machineId: genericMid, hardwareModel: nil,
                             mac: "5e:11:22:33:44:55", disk: diskURL.path, aux: nil,
                             nvram: persistentNVRAMURL.path, iso: nil, cpu: 2,
                             mem: 2_147_483_648, gui: false, width: 1024, height: 768,
                             share: nil, createNVRAM: false)
    let normal = try prepareRunOptions(normalOpts, temporaryRoot: vmDir)
    check("normal.nvram.persistent", normal.options.nvram == persistentNVRAMURL.path)
    check("normal.nvram.reuses", !normal.options.createNVRAM)
    check("normal.nvram.no-temp", normal.temporaryDirectory == nil)
    check("normal.not-recovery", !normal.options.recovery)
} catch {
    FileHandle.standardError.write(Data("FAIL: recovery.nvram \(error)\n".utf8))
    failures += 1
}

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
    if let iso = guiCfg.storageDevices.first as? VZUSBMassStorageDeviceConfiguration,
       let attachment = iso.attachment as? VZDiskImageStorageDeviceAttachment {
        check("efi.storage.iso-read-only", attachment.isReadOnly)
    } else {
        check("efi.storage.iso-read-only", false)
    }
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
