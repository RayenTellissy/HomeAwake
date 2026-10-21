import Foundation

public let agentLabel = "dev.homeawake.agent"
public let sudoersPath = "/etc/sudoers.d/homeawake"

/// The exact argument vectors the sudoers rule allows.
public enum Pmset {
    public static let allowSleep = ["/usr/bin/pmset", "-a", "disablesleep", "0"]
    public static let preventSleep = ["/usr/bin/pmset", "-a", "disablesleep", "1"]

    /// Spelled the same way in the sudoers file and in `sudo -l` output.
    static let ruleCommands = [allowSleep, preventSleep].map { $0.joined(separator: " ") }
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
func passwordlessRootCommands(_ sudoList: String) -> Set<String> {
    var entries: [String] = []
    for line in sudoList.split(separator: "\n") {
        let text = line.drop(while: \.isWhitespace)
        if text.hasPrefix("(") {
            entries.append(String(text))
        } else if !entries.isEmpty, text.startIndex != line.startIndex {
            entries[entries.count - 1] += " " + text
        }
    }
    let spec = "(root) NOPASSWD: "
    return Set(entries.flatMap { entry in
        let flat = entry.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.hasPrefix(spec) ? flat.dropFirst(spec.count).components(separatedBy: ", ") : []
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

public func launchAgentPlist(agentPath: String) -> Data {
    let plist: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": [agentPath],
        "RunAtLoad": true,
        "KeepAlive": true,
        "ProcessType": "Background",
    ]
    return try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
}
