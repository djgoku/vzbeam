import Foundation

public enum GuestOS: String {
    case macos
    case openbsd

    public static func parse(_ value: String?) throws -> GuestOS {
        guard let value, let guest = GuestOS(rawValue: value) else {
            throw ConfigError.badField("guest")
        }
        return guest
    }
}
