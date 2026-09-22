import Foundation

public struct RunPreparation {
    public let options: RunOpts
    public let temporaryDirectory: URL?
}

public func prepareRunOptions(
    _ options: RunOpts,
    temporaryRoot: URL = FileManager.default.temporaryDirectory
) throws -> RunPreparation {
    guard options.guest == .openbsd, options.iso != nil else {
        return RunPreparation(options: options, temporaryDirectory: nil)
    }

    let directory = temporaryRoot.appendingPathComponent(
        "vzbeam-recovery-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )

    let temporaryNVRAM = directory.appendingPathComponent("nvram.bin")
    let prepared = RunOpts(
        guest: options.guest,
        machineId: options.machineId,
        hardwareModel: options.hardwareModel,
        mac: options.mac,
        disk: options.disk,
        aux: options.aux,
        nvram: temporaryNVRAM.path,
        iso: options.iso,
        cpu: options.cpu,
        mem: options.mem,
        gui: options.gui,
        width: options.width,
        height: options.height,
        share: options.share,
        createNVRAM: true,
        recovery: options.recovery
    )

    return RunPreparation(options: prepared, temporaryDirectory: directory)
}

public func cleanupRunPreparation(_ preparation: RunPreparation) {
    guard let directory = preparation.temporaryDirectory else { return }
    try? FileManager.default.removeItem(at: directory)
}
