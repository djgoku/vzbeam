import Virtualization
import Foundation

public func mintIdentity(for guest: GuestOS) -> (machineId: String, mac: String) {
    let machineId: String
    switch guest {
    case .macos:
        machineId = VZMacMachineIdentifier().dataRepresentation.base64EncodedString()
    case .openbsd:
        machineId = VZGenericMachineIdentifier().dataRepresentation.base64EncodedString()
    }
    return (machineId, VZMACAddress.randomLocallyAdministered().string)
}

public func runReid(_ args: [String]) {
    do {
        let guest = try GuestOS.parse(Args(args).value("guest"))
        let (mid, mac) = mintIdentity(for: guest)
        Wire.emit(["type": "reid", "machineIdentifier": mid, "macAddress": mac])
    } catch {
        let fields = Wire.errorFields(error)
        Wire.emitError(domain: fields.domain, code: fields.code, fields.message)
        exit(2)
    }
}
