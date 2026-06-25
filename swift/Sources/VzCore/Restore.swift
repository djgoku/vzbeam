import Virtualization
import Foundation

private var liveRestore: RestoreSession?

public func runRestore(_ args: [String]) {
    liveRestore = RestoreSession(args)
    liveRestore?.start()
}

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
            // load's completion fires on a background queue, but VZMacOSInstaller /
            // VZVirtualMachine assert they are created and used on the VM's (main) queue
            // (dispatch_assert_queue trap otherwise). Hop to main before creating them.
            DispatchQueue.main.async {
                switch result {
                case .failure(let e): self?.fail(domain: "VZErrorDomain", code: (e as NSError).code, e.localizedDescription)
                case .success(let image): self?.install(image, ipswURL, disk, aux, diskSize, cpu, mem)
                }
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
                let ns = e as NSError
                // VZError 10007 ("Installation failed.") is opaque; the actionable reason is the
                // underlying error (e.g. MobileRestore codes). Fold it into the surfaced message.
                let detail: String
                if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                    detail = "\(ns.localizedDescription) (\(under.domain) \(under.code): \(under.localizedDescription))"
                } else {
                    detail = ns.localizedDescription
                }
                self?.fail(domain: ns.domain, code: ns.code, detail)
            }
        }
    }

    private func fail(domain: String, code: Int, _ message: String) {
        Wire.emit(["type": "error", "domain": domain, "code": code, "message": message]); exit(1)
    }
}
