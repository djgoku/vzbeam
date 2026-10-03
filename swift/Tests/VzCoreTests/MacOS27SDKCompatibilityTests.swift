import Virtualization
import XCTest
@testable import VzCore

final class MacOS27SDKCompatibilityTests: XCTestCase {
    func testGuestProvisioningOptionsCanBeAttachedToMacStartOptions() throws {
#if compiler(>=6.4)
        guard #available(macOS 27.0, *) else {
            throw XCTSkip("the macOS 27 provisioning API requires a macOS 27 host")
        }

        let provisioning = VZMacGuestProvisioningOptions()
        provisioning.fullName = "CI User"
        provisioning.username = "ci-user"
        provisioning.password = "temporary"
        provisioning.enablesRemoteLogin = true
        provisioning.logsInAutomatically = false

        XCTAssertEqual(provisioning.fullName, "CI User")
        XCTAssertEqual(provisioning.username, "ci-user")
        XCTAssertTrue(provisioning.enablesRemoteLogin)
        XCTAssertFalse(provisioning.logsInAutomatically)

        let startOptions = VZMacOSVirtualMachineStartOptions()
        XCTAssertNoThrow(try startOptions.setGuestProvisioning(provisioning))
#else
        throw XCTSkip("the macOS 27 provisioning API requires Swift 6.4 or newer")
#endif
    }
}
