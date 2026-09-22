import Virtualization
import Foundation

func buildEFIConfiguration(_ o: RunOpts) throws -> VZVirtualMachineConfiguration {
    guard let idData = Data(base64Encoded: o.machineId),
          let genericID = VZGenericMachineIdentifier(dataRepresentation: idData) else {
        throw ConfigError.badField("machine-id")
    }
    guard let mac = VZMACAddress(string: o.mac) else { throw ConfigError.badField("mac") }
    guard let nvram = o.nvram, !nvram.isEmpty else { throw ConfigError.badField("nvram") }

    let platform = VZGenericPlatformConfiguration()
    platform.machineIdentifier = genericID

    let nvramURL = URL(fileURLWithPath: nvram)
    let variableStore: VZEFIVariableStore
    if o.createNVRAM {
        variableStore = try VZEFIVariableStore(creatingVariableStoreAt: nvramURL, options: [])
    } else {
        guard FileManager.default.fileExists(atPath: nvramURL.path) else {
            throw ConfigError.badField("nvram")
        }
        variableStore = VZEFIVariableStore(url: nvramURL)
    }

    let boot = VZEFIBootLoader()
    boot.variableStore = variableStore

    let cfg = VZVirtualMachineConfiguration()
    cfg.platform = platform
    cfg.bootLoader = boot
    cfg.cpuCount = o.cpu
    cfg.memorySize = o.mem

    let isoAttachment = try o.iso.map {
        try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: $0), readOnly: true)
    }
    var storage: [VZStorageDeviceConfiguration] = []
    if let isoAttachment {
        storage.append(VZUSBMassStorageDeviceConfiguration(attachment: isoAttachment))
    }
    if o.recovery {
        guard #available(macOS 15.0, *) else {
            throw ConfigError.unsupported("OpenBSD recovery requires macOS 15 or newer")
        }
        cfg.usbControllers = [VZXHCIControllerConfiguration()]
    } else {
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: URL(fileURLWithPath: o.disk), readOnly: false)
        storage.append(VZVirtioBlockDeviceConfiguration(attachment: diskAttachment))
    }
    cfg.storageDevices = storage

    let net = VZVirtioNetworkDeviceConfiguration()
    net.attachment = VZNATNetworkDeviceAttachment()
    net.macAddress = mac
    cfg.networkDevices = [net]

    let graphics = VZVirtioGraphicsDeviceConfiguration()
    graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(
        widthInPixels: o.width, heightInPixels: o.height)]
    cfg.graphicsDevices = [graphics]
    cfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

    if o.gui {
        cfg.keyboards = [VZUSBKeyboardConfiguration()]
        cfg.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    try cfg.validate()
    return cfg
}
