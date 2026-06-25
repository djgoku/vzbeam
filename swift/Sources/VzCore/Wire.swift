import Foundation

public enum Wire {
    /// One compact JSON line on stdout + newline + flush. Keys sorted for stable output.
    public static func emit(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            log("vz: failed to serialize event"); return
        }
        print(line)        // print adds "\n"
        fflush(stdout)
    }
    public static func log(_ msg: String) {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
    }
}
