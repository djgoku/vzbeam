import Virtualization
import Foundation

public struct RunOpts {
    public let guest: GuestOS
    public let machineId: String
    public let hardwareModel: String?
    public let mac: String
    public let disk: String
    public let aux: String?
    public let nvram: String?
    public let iso: String?
    public let cpu: Int
    public let mem: UInt64
    public let gui: Bool
    public let width: Int
    public let height: Int
    public let share: (tag: String, path: String)?
    public let createNVRAM: Bool
    public let recovery: Bool
    public let name: String?          // bundle name, shown in the window title

    public init(guest: GuestOS, machineId: String, hardwareModel: String?,
                mac: String, disk: String, aux: String?, nvram: String?,
                iso: String?, cpu: Int, mem: UInt64, gui: Bool,
                width: Int, height: Int, share: (String, String)?,
                createNVRAM: Bool, recovery: Bool = false, name: String? = nil) {
        self.guest = guest
        self.machineId = machineId
        self.hardwareModel = hardwareModel
        self.mac = mac
        self.disk = disk
        self.aux = aux
        self.nvram = nvram
        self.iso = iso
        self.cpu = cpu
        self.mem = mem
        self.gui = gui
        self.width = width
        self.height = height
        self.share = share.map { (tag: $0.0, path: $0.1) }
        self.createNVRAM = createNVRAM
        self.recovery = recovery
        self.name = name
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case badField(String)
    case unsupported(String)
    public var description: String {
        switch self {
        case .badField(let f): return "invalid \(f)"
        case .unsupported(let message): return message
        }
    }
}

public func buildConfiguration(_ opts: RunOpts) throws -> VZVirtualMachineConfiguration {
    switch opts.guest {
    case .macos:
        guard opts.nvram == nil, opts.iso == nil else {
            throw ConfigError.badField("macos-options")
        }
        return try buildMacConfiguration(opts)
    case .openbsd:
        guard opts.hardwareModel == nil, opts.aux == nil, opts.share == nil else {
            throw ConfigError.badField("openbsd-options")
        }
        return try buildEFIConfiguration(opts)
    }
}
