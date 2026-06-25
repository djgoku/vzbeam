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

    /// One `{"type":"error",…}` line — the standard error-event shape.
    public static func emitError(domain: String, code: Int, _ message: String) {
        emit(["type": "error", "domain": domain, "code": code, "message": message])
    }

    /// Map an Error to the (domain, code, message) we put on the wire. Our own
    /// ConfigError (a usage/validation failure) becomes domain "vz" + code 2; a
    /// framework NSError keeps its domain/code, with any NSUnderlyingError (e.g. the
    /// opaque VZError 10007 that wraps a MobileRestore code) folded into the message
    /// so the engine surfaces the actionable reason.
    public static func errorFields(_ error: Error) -> (domain: String, code: Int, message: String) {
        if let cfg = error as? ConfigError { return ("vz", 2, cfg.description) }
        let ns = error as NSError
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return (ns.domain, ns.code,
                    "\(ns.localizedDescription) (\(under.domain) \(under.code): \(under.localizedDescription))")
        }
        return (ns.domain, ns.code, ns.localizedDescription)
    }
    public static func log(_ msg: String) {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
    }
}
