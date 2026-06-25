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
