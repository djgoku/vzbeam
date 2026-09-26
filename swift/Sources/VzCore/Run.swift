import Virtualization
import AppKit
import Foundation

// File-scope strong holder: prevents ARC from deallocating the session before
// its async [weak self] handlers fire in release mode (Task 8 fix).
private var liveRun: RunSession?

public func runRun(_ args: [String]) {
    if setsid() == -1 { Wire.log("vz: setsid failed: \(String(cString: strerror(errno)))") }  // in-process, no fork: getpid() stays == the launch pid the engine captured
    let opts: RunOpts
    do { opts = try parseRunOpts(args) }
    catch {
        let fields = Wire.errorFields(error)
        Wire.emitError(domain: fields.domain, code: fields.code, "run: \(fields.message)")
        exit(2)
    }
    liveRun = RunSession(opts: opts)
    liveRun?.start()
}

public func parseRunOpts(_ args: [String]) throws -> RunOpts {
    let a = Args(args, booleanFlags: ["gui", "headless"], pairFlags: ["share"])
    let guest = try GuestOS.parse(a.value("guest"))
    guard let mid = a.value("machine-id"), let mac = a.value("mac"),
          let disk = a.value("disk"),
          let cpu = a.value("cpu").flatMap(Int.init), let mem = a.value("mem").flatMap(UInt64.init) else {
        throw ConfigError.badField("required flags")
    }
    let (w, h) = parseResolution(a.value("resolution") ?? "1920x1200")
    let share = a.pair("share").map { (tag: $0.0, path: $0.1) }
    let hardwareModel = a.value("hardware-model")
    let aux = a.value("aux")
    let nvram = a.value("nvram")
    let iso = a.value("iso")

    switch guest {
    case .macos:
        guard hardwareModel != nil, aux != nil, nvram == nil, iso == nil else {
            throw ConfigError.badField("macos options")
        }
    case .openbsd:
        guard nvram != nil, hardwareModel == nil, aux == nil, share == nil else {
            throw ConfigError.badField("openbsd options")
        }
    }

    return RunOpts(guest: guest, machineId: mid, hardwareModel: hardwareModel,
                   mac: mac, disk: disk, aux: aux, nvram: nvram, iso: iso,
                   cpu: cpu, mem: mem, gui: a.has("gui"), width: w, height: h,
                   share: share, createNVRAM: false,
                   recovery: guest == .openbsd && iso != nil)
}

private func parseResolution(_ s: String) -> (Int, Int) {
    let parts = s.lowercased().split(separator: "x")
    if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) { return (w, h) }
    return (1920, 1200)
}

final class RunSession: NSObject, VZVirtualMachineDelegate {
    // Keep the installed disk absent while EFI commits to the only bootable device.
    // Attaching earlier reproduced nondeterministic disk-first boots on hardware.
    private static let recoveryDiskAttachDelay: TimeInterval = 5

    private let opts: RunOpts
    private var vm: VZVirtualMachine?
    private var preparation: RunPreparation?
    private var finished = false           // only touched on .main → no lock needed
    private var sig: DispatchSourceSignal?
    private var window: VMWindow?          // --gui only

    init(opts: RunOpts) { self.opts = opts }

    func start() {
        let cfg: VZVirtualMachineConfiguration
        do {
            let preparation = try prepareRunOptions(opts)
            self.preparation = preparation
            cfg = try buildConfiguration(preparation.options)
        }
        catch { return finishError(error) }

        let vm = VZVirtualMachine(configuration: cfg)   // main queue
        vm.delegate = self; self.vm = vm
        installSignalTrap()
        vm.start { [weak self] result in
            switch result {
            case .success: self?.completeStart(vm: vm)
            case .failure(let e): self?.finishError(e)
            }
        }
        if opts.gui { runGUI(vm: vm) } else { RunLoop.main.run() }
    }

    private func installSignalTrap() {
        signal(SIGTERM, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            guard let vm = self.vm else { self.finishStopped(); return }
            vm.stop { [weak self] error in
                if let error { self?.finishError(error) } else { self?.finishStopped() }
            }
        }
        s.resume(); sig = s
    }

    private func completeStart(vm: VZVirtualMachine) {
        guard opts.recovery else { return emitStarted() }
        guard #available(macOS 15.0, *), let controller = vm.usbControllers.first else {
            return finishError(ConfigError.unsupported("OpenBSD recovery requires macOS 15 or newer"))
        }

        let device: VZUSBMassStorageDevice
        do {
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: opts.disk), readOnly: false)
            let configuration = VZUSBMassStorageDeviceConfiguration(attachment: attachment)
            device = VZUSBMassStorageDevice(configuration: configuration)
        } catch {
            return finishError(error)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recoveryDiskAttachDelay) { [weak self] in
            guard let self, !self.finished else { return }
            controller.attach(device: device) { [weak self] error in
                if let error {
                    self?.finishError(error)
                } else {
                    self?.emitStarted()
                }
            }
        }
    }

    private func emitStarted() {
        guard !finished else { return }
        Wire.emit(["type": "started", "pid": Int(getpid())])
    }

    // VZVirtualMachineDelegate (fires on the main queue)
    func guestDidStop(_ virtualMachine: VZVirtualMachine) { finishStopped() }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
        finishError(error)
    }

    // Single terminal-emission path — idempotent, main-thread only.
    private func finishStopped() { finishOnce { Wire.emit(["type": "guest_stopped"]); exit(0) } }
    private func finishError(_ error: Error) {
        let f = Wire.errorFields(error); finishError(domain: f.domain, code: f.code, f.message)
    }
    private func finishError(domain: String, code: Int, _ message: String) {
        finishOnce { Wire.emitError(domain: domain, code: code, message); exit(1) }
    }
    private func finishOnce(_ body: () -> Void) {
        if finished { return }
        finished = true
        if let preparation {
            cleanupRunPreparation(preparation)
            self.preparation = nil
        }
        body()
    }

    private func runGUI(vm: VZVirtualMachine) {
        let win = VMWindow(vm: vm, title: "vzbeam", width: opts.width, height: opts.height)
        window = win
        win.run()
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
