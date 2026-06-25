import VzCore
import Foundation
import Virtualization

var failures = 0
func check(_ name: String, _ cond: Bool) {
    FileHandle.standardError.write(Data(((cond ? "ok: " : "FAIL: ") + name + "\n").utf8))
    if !cond { failures += 1 }
}

// --- Args ---
let a = Args(["run", "--mac", "5e:1", "--headless", "--share", "tag", "/p"],
             booleanFlags: ["headless"], pairFlags: ["share"])
check("args.positional", a.positionals == ["run"])
check("args.value", a.value("mac") == "5e:1")
check("args.bool", a.has("headless"))
check("args.pair.tag", a.pair("share")?.0 == "tag")
check("args.pair.path", a.pair("share")?.1 == "/p")

// --- Wire ---
if let line = Wire.encode(["type": "version", "protocol": 1]) {
    check("wire.singleLine", !line.contains("\n"))
    if let data = line.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        check("wire.type", obj["type"] as? String == "version")
        check("wire.protocol", obj["protocol"] as? Int == 1)
    } else { check("wire.parse", false) }
} else { check("wire.encode", false) }

// --- ReID ---
let (mid, mac) = mintIdentity()
check("reid.mid.base64", !mid.isEmpty && Data(base64Encoded: mid) != nil)
check("reid.mac.format", mac.range(of: #"^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$"#, options: .regularExpression) != nil)

// --- validateTag (VZVirtioFileSystemDeviceConfiguration) ---
check("tag.valid", (try? VZVirtioFileSystemDeviceConfiguration.validateTag("share")) != nil)
check("tag.empty", (try? VZVirtioFileSystemDeviceConfiguration.validateTag("")) == nil)
check("tag.toolong", (try? VZVirtioFileSystemDeviceConfiguration.validateTag(String(repeating: "a", count: 37))) == nil)

FileHandle.standardError.write(Data((failures == 0 ? "ALL CHECKS PASS\n" : "\(failures) CHECK(S) FAILED\n").utf8))
exit(failures == 0 ? 0 : 1)
