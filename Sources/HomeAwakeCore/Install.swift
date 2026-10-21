import Foundation

public let agentLabel = "dev.homeawake.agent"
public let sudoersPath = "/etc/sudoers.d/homeawake"

/// The exact argument vectors the sudoers rule allows. Both executables run these constants, so the rule and the
/// calls cannot drift apart.
public enum Pmset {
    public static let allowSleep = ["/usr/bin/pmset", "-a", "disablesleep", "0"]
    public static let preventSleep = ["/usr/bin/pmset", "-a", "disablesleep", "1"]
    public static let sleepNow = ["/usr/bin/pmset", "sleepnow"]

    /// The rule's command list, spelled the same way in the sudoers file and in `sudo -l` output.
    static let ruleCommands = [allowSleep, preventSleep, sleepNow].map { $0.joined(separator: " ") }
        .joined(separator: ", ")
}

/// Nil for a user name that sudoers or the shell would need escaped. macOS short names never do.
public func sudoersRule(user: String) -> String? {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    guard !user.isEmpty, user.allSatisfy(allowed.contains) else { return nil }
    return "\(user) ALL=(root) NOPASSWD: \(Pmset.ruleCommands)"
}

/// True when `sudo -n -l` output lists the whole HomeAwake rule. The exit status proves nothing: any NOPASSWD rule
/// lets `sudo -n -l` succeed, and other tools' rules can grant some of these pmset commands on their own.
public func listsLidModeRule(_ sudoList: String) -> Bool {
    // Collapsing whitespace undoes sudo's wrapping of long entries at 80 columns.
    let flat = sudoList.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return flat.contains("(root) NOPASSWD: \(Pmset.ruleCommands)")
}

/// AppleScript source that installs the rule behind one admin prompt. visudo checks the file before it goes live, and
/// `install -S` renames it into place so sudo never reads a half-written rule.
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
    // Strings, booleans, and an array of strings always serialize.
    return try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
}
