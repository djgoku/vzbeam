/// Tiny flag parser. `--k v` value flags by default; `booleanFlags` take no value;
/// `pairFlags` consume the next TWO args (e.g. `--share <tag> <path>`).
public struct Args {
    public let positionals: [String]
    private let options: [String: String]
    private let flags: Set<String>
    private let pairs: [String: (String, String)]

    public init(_ argv: [String], booleanFlags: Set<String> = [], pairFlags: Set<String> = []) {
        var pos: [String] = []; var opts: [String: String] = [:]
        var flgs: Set<String> = []; var prs: [String: (String, String)] = [:]
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if booleanFlags.contains(key) { flgs.insert(key); i += 1 }
                else if pairFlags.contains(key), i + 2 < argv.count {
                    prs[key] = (argv[i + 1], argv[i + 2]); i += 3
                } else if i + 1 < argv.count { opts[key] = argv[i + 1]; i += 2 }
                else { flgs.insert(key); i += 1 }
            } else { pos.append(a); i += 1 }
        }
        positionals = pos; options = opts; flags = flgs; pairs = prs
    }
    public func value(_ k: String) -> String? { options[k] }
    public func has(_ k: String) -> Bool { flags.contains(k) }
    public func pair(_ k: String) -> (String, String)? { pairs[k] }
}
