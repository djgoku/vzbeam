import Virtualization
import AppKit
import Foundation

// File-scope strong holder: prevents ARC from deallocating the session before
// its async [weak self] handlers fire in release mode (Task 8 fix).
private var liveRun: RunSession?

public func runRun(_ args: [String]) {
    if setsid() == -1 { Wire.log("vz: setsid failed: \(String(cString: strerror(errno)))") }  // in-process, no fork: getpid() stays == the launch pid the engine captured (Codex #5)
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
    liveRun = RunSession(opts: opts)
    liveRun?.start()
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
        s.setEventHandler { [weak self] in
            guard let self else { return }
            guard let vm = self.vm else { self.finishStopped(); return }
            vm.stop { [weak self] error in
                if let error {
                    self?.finishError(domain: (error as NSError).domain, code: (error as NSError).code,
                                      error.localizedDescription)
                } else {
                    self?.finishStopped()
                }
            }
        }
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
        app.setActivationPolicy(.regular)   // .regular gives a Dock icon so the first-boot window is findable
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
