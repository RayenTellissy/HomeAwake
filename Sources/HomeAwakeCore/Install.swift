import Foundation

public enum LaunchAgent: String, Sendable {
    case agent = "dev.homeawake.agent"
    case menu = "dev.homeawake.menu"

    public var executable: String { self == .agent ? "homeawake-agent" : "HomeAwake" }
    public var plistFile: URL { URL.libraryDirectory.appending(path: "LaunchAgents/\(rawValue).plist") }
}

let sudoersPath = "/etc/sudoers.d/homeawake"

/// The exact argument vectors the sudoers rule allows.
enum Pmset {
    static func disablesleep(_ on: Bool) -> [String] { ["/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"] }

    /// Spelled the same way in the sudoers file and in `sudo -l` output.
    static let ruleCommands = [false, true].map { disablesleep($0).joined(separator: " ") }
}

/// Nil for a user name that sudoers or the shell would need escaped.
public func sudoersRule(user: String) -> String? {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    guard !user.isEmpty, user.allSatisfy(allowed.contains) else { return nil }
    return "\(user) ALL=(root) NOPASSWD: \(Pmset.ruleCommands.joined(separator: ", "))"
}

/// True when `sudo -n -l` output grants both pmset commands without a password, from any rule, HomeAwake's or another
/// tool's. The exit status proves nothing: any NOPASSWD rule lets `sudo -n -l` succeed.
public func grantsLidMode(sudoList: String) -> Bool {
    Set(Pmset.ruleCommands).isSubset(of: passwordlessRootCommands(sudoList))
}

/// sudo prints one entry per line for separate sudoers lines, but joins one rule's commands with ", " into one entry.
/// It wraps long entries only on a terminal, and `run` gives it a pipe.
func passwordlessRootCommands(_ sudoList: String) -> Set<String> {
    let spec = "(root) NOPASSWD: "
    return Set(sudoList.split(separator: "\n").flatMap { line in
        let entry = line.drop(while: \.isWhitespace)
        return entry.hasPrefix(spec) ? entry.dropFirst(spec.count).components(separatedBy: ", ") : []
    })
}

/// AppleScript source that installs the rule behind one admin prompt.
public func installScript(user: String) -> String? {
    guard let rule = sudoersRule(user: user) else { return nil }
    let shell = [
        #"t=$(/usr/bin/mktemp) && /usr/bin/printf '%s\n' '\#(rule)' > "$t""#,
        #"/usr/sbin/visudo -cf "$t""#,
        #"/usr/bin/install -S -m 0440 -o root -g wheel "$t" \#(sudoersPath); s=$?; /bin/rm -f "$t"; exit $s"#,
    ].joined(separator: " && ")
    let quoted = shell.replacingOccurrences(of: #"\"#, with: #"\\"#).replacingOccurrences(of: #"""#, with: #"\""#)
    return #"do shell script "\#(quoted)" with administrator privileges"#
}

/// The menu app restarts after a crash but not after a deliberate quit, and only in a login session with a menu bar.
public func launchAgentPlist(_ agent: LaunchAgent, executablePath: String) throws -> Data {
    let keys: [String: Any] = switch agent {
    case .agent: ["KeepAlive": true, "ProcessType": "Background"]
    case .menu: ["KeepAlive": ["SuccessfulExit": false], "LimitLoadToSessionType": "Aqua"]
    }
    let plist = keys.merging(["Label": agent.rawValue, "ProgramArguments": [executablePath], "RunAtLoad": true]) { $1 }
    return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
}

/// Reads the top-level `pid = 88428` line of `launchctl print` output, which is there only while the job runs.
public func launchdPID(print: String) -> Int32? {
    print.split(separator: "\n").lazy.compactMap { $0.hasPrefix("\tpid = ") ? Int32($0.dropFirst(7)) : nil }.first
}
