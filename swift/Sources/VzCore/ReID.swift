import Virtualization
import Foundation

public func mintIdentity() -> (machineId: String, mac: String) {
    (VZMacMachineIdentifier().dataRepresentation.base64EncodedString(),
     VZMACAddress.randomLocallyAdministered().string)
}

public func runReid() {
    let (mid, mac) = mintIdentity()
    Wire.emit(["type": "reid", "machineIdentifier": mid, "macAddress": mac])
}
