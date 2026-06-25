import Foundation

public enum Wire {
    /// Pure: compact JSON (keys sorted) as a single line, or nil on failure.
    public static func encode(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    /// One compact JSON line on stdout + newline + flush.
    public static func emit(_ obj: [String: Any]) {
        guard let line = encode(obj) else { log("vz: failed to serialize event"); return }
        print(line)        // print adds "\n"
        fflush(stdout)
    }
    public static func log(_ msg: String) {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
    }
}
