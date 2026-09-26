import Virtualization
import AppKit
import Foundation
import Darwin

private var liveInstall: InstallSession?

private enum InstallState {
    case starting
    case running
    case finishing
    case finished
}

public struct InstallOpts {
    public let guest: GuestOS
    public let iso: String
    public let disk: String
    public let nvram: String
    public let cpu: Int
    public let mem: UInt64
    public let width: Int
    public let height: Int
    public let parentPID: pid_t
}

public func parseInstallOpts(_ args: [String]) throws -> InstallOpts {
    let a = Args(args)
    let guest = try GuestOS.parse(a.value("guest"))
    guard guest == .openbsd else { throw ConfigError.badField("guest") }
    guard let iso = nonempty(a.value("iso")) else { throw ConfigError.badField("iso") }
    guard let disk = nonempty(a.value("disk")) else { throw ConfigError.badField("disk") }
    guard let nvram = nonempty(a.value("nvram")) else { throw ConfigError.badField("nvram") }
    guard let cpu = a.value("cpu").flatMap(Int.init), cpu > 0 else {
        throw ConfigError.badField("cpu")
    }
    guard let mem = a.value("mem").flatMap(UInt64.init), mem > 0 else {
        throw ConfigError.badField("mem")
    }
    guard let parentPID = a.value("parent-pid").flatMap(Int32.init), parentPID > 0 else {
        throw ConfigError.badField("parent-pid")
    }
    let (width, height) = try installResolution(a.value("resolution"))
    return InstallOpts(guest: guest, iso: iso, disk: disk, nvram: nvram,
                       cpu: cpu, mem: mem, width: width, height: height,
                       parentPID: parentPID)
}

private func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

private func installResolution(_ value: String?) throws -> (Int, Int) {
    guard let value else { throw ConfigError.badField("resolution") }
    let parts = value.lowercased().split(separator: "x", omittingEmptySubsequences: false)
    guard parts.count == 2,
          let width = Int(parts[0]), width > 0,
          let height = Int(parts[1]), height > 0 else {
        throw ConfigError.badField("resolution")
    }
    return (width, height)
}

public func runInstall(_ args: [String]) {
    let install: InstallOpts
    do { install = try parseInstallOpts(args) }
    catch {
        let fields = Wire.errorFields(error)
        Wire.emitError(domain: fields.domain, code: fields.code, fields.message)
        exit(2)
    }

    let (machineId, mac) = mintIdentity(for: .openbsd)
    let run = RunOpts(guest: install.guest, machineId: machineId, hardwareModel: nil,
                      mac: mac, disk: install.disk, aux: nil, nvram: install.nvram,
                      iso: install.iso, cpu: install.cpu, mem: install.mem,
                      gui: true, width: install.width, height: install.height,
                      share: nil, createNVRAM: true)
    let session = InstallSession(install: install, run: run,
                                 machineId: machineId, mac: mac)
    liveInstall = session
    session.start()
}

private final class InstallSession: NSObject, VZVirtualMachineDelegate {
    private let install: InstallOpts
    private let run: RunOpts
    private let machineId: String
    private let mac: String
    private var state: InstallState = .starting
    private var vm: VZVirtualMachine?
    private var window: VMWindow?
    private var signals: [DispatchSourceSignal] = []
    private var parentTimer: DispatchSourceTimer?
    private var cancellationDeadline: DispatchSourceTimer?

    init(install: InstallOpts, run: RunOpts, machineId: String, mac: String) {
        self.install = install
        self.run = run
        self.machineId = machineId
        self.mac = mac
    }

    func start() {
        let configuration: VZVirtualMachineConfiguration
        do { configuration = try buildConfiguration(run) }
        catch { return finishFailure(error) }

        let vm = VZVirtualMachine(configuration: configuration)
        vm.delegate = self
        self.vm = vm
        installCancellationSources()
        startParentWatchdog()
        vm.start { [weak self] result in
            DispatchQueue.main.async { self?.handleStart(result) }
        }
        runGUI(vm: vm)
    }

    private func handleStart(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            guard state == .starting else { return }
            state = .running
            Wire.emit(["type": "install_started", "pid": Int(getpid())])
        case .failure(let error):
            finishFailure(error)
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        switch state {
        case .running:
            finishInstalled()
        case .starting:
            finishFailure(domain: "vz", code: 1, "installation stopped during startup")
        case .finishing:
            finishCancelled()
        case .finished:
            break
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        finishFailure(error)
    }

    private func installCancellationSources() {
        for signum in [SIGINT, SIGTERM, SIGHUP] {
            signal(signum, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signum, queue: .main)
            source.setEventHandler { [weak self] in self?.cancelInstallation() }
            source.resume()
            signals.append(source)
        }
    }

    private func startParentWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if kill(self.install.parentPID, 0) == -1 && errno == ESRCH {
                self.cancelInstallation()
            }
        }
        timer.resume()
        parentTimer = timer
    }

    private func cancelInstallation() {
        guard state != .finishing, state != .finished else { return }
        state = .finishing

        let deadline = DispatchSource.makeTimerSource(queue: .main)
        deadline.schedule(deadline: .now() + 5)
        deadline.setEventHandler { [weak self] in self?.finishCancelled() }
        deadline.resume()
        cancellationDeadline = deadline

        guard let vm else { return finishCancelled() }
        vm.stop { [weak self] _ in
            DispatchQueue.main.async { self?.finishCancelled() }
        }
    }

    private func finishInstalled() {
        finishOnce {
            Wire.emit(["type": "installed", "machineIdentifier": machineId,
                       "macAddress": mac])
            exit(0)
        }
    }

    private func finishFailure(_ error: Error) {
        if state == .finishing { return finishCancelled() }
        let fields = Wire.errorFields(error)
        finishFailure(domain: fields.domain, code: fields.code, fields.message)
    }

    private func finishFailure(domain: String, code: Int, _ message: String) {
        if state == .finishing { return finishCancelled() }
        finishOnce {
            Wire.emitError(domain: domain, code: code, message)
            exit(1)
        }
    }

    private func finishCancelled() {
        finishOnce {
            Wire.emitError(domain: "vz", code: 130, "install cancelled")
            exit(1)
        }
    }

    private func finishOnce(_ body: () -> Void) {
        guard state != .finished else { return }
        state = .finished
        signals.forEach { $0.cancel() }
        signals.removeAll()
        parentTimer?.cancel()
        parentTimer = nil
        cancellationDeadline?.cancel()
        cancellationDeadline = nil
        body()
    }

    // Closing the window only hides it, as with `run --gui`; Ctrl-C in the terminal (SIGINT),
    // SIGTERM/SIGHUP, or the parent exiting is what cancels the installation.
    private func runGUI(vm: VZVirtualMachine) {
        let window = VMWindow(vm: vm, title: "vzbeam OpenBSD installer", width: run.width, height: run.height)
        self.window = window
        window.run()
    }
}
