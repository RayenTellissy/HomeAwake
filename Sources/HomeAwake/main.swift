import AppKit
import HomeAwakeCore
import notify

struct Failure: LocalizedError { var errorDescription: String? }

let service = "gui/\(getuid())/\(agentLabel)"

func agentService() -> (loaded: Bool, running: Bool) {
    let print = run(["/bin/launchctl", "print", service])
    return (print.ok, print.output.contains("state = running"))
}

/// Writes the LaunchAgent when it is missing or stale and loads it when needed, so opening the app twice still
/// leaves exactly one agent.
func installAgent() throws {
    let agent = Bundle.main.bundleURL.appending(path: "Contents/MacOS/homeawake-agent")
    let plist = launchAgentPlist(agentPath: agent.path)
    let loaded = agentService().loaded
    guard (try? Data(contentsOf: Files.launchAgent)) != plist || !loaded else { return }
    if loaded { run(["/bin/launchctl", "bootout", service]) }
    try FileManager.default.createDirectory(
        at: Files.launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
    try plist.write(to: Files.launchAgent, options: .atomic)
    guard run(["/bin/launchctl", "bootstrap", "gui/\(getuid())", Files.launchAgent.path]).ok else {
        throw Failure(errorDescription: "launchctl could not load the HomeAwake agent.")
    }
    // The agent writes its first status right after it starts.
    for _ in 0..<20 where !FileManager.default.fileExists(atPath: Files.status.path) { usleep(100_000) }
}

func updatePrefs(_ change: (inout Prefs) -> Void) throws {
    var prefs = load(Prefs.self, from: Files.prefs) ?? Prefs()
    change(&prefs)
    try save(prefs, to: Files.prefs)
    notify_post(prefsChanged)
}

func setUpLidMode() throws {
    guard let source = installScript(user: NSUserName()) else {
        throw Failure(errorDescription: "Your user name cannot go in a sudoers rule.")
    }
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error { throw Failure(errorDescription: error[NSAppleScript.errorMessage] as? String ?? "Setup failed.") }
    notify_post(prefsChanged)
}

func remove() {
    run(["/bin/launchctl", "bootout", service])
    try? FileManager.default.removeItem(at: Files.launchAgent)
    // A running agent gives the switch back on SIGTERM. This covers one that was not running.
    if var status = load(AgentStatus.self, from: Files.status), status.ownsSleepSwitch,
       run(["/usr/bin/sudo", "-n"] + Pmset.allowSleep).ok {
        status.ownsSleepSwitch = false
        try? save(status, to: Files.status)
    }
}

NSApplication.shared.setActivationPolicy(.regular)
NSApp.activate()

var problem: String?
do { try installAgent() } catch { problem = error.localizedDescription }

while true {
    let prefs = load(Prefs.self, from: Files.prefs) ?? Prefs()
    let snapshot = load(AgentStatus.self, from: Files.status)?.snapshot
    let lidMode = lidModeInstalled()

    let alert = NSAlert()
    alert.messageText = switch (agentService().running, snapshot) {
    case (false, _): "The HomeAwake agent is not running."
    case (true, nil): "HomeAwake is starting."
    case let (true, snapshot?): statusLine(decide(snapshot, prefs), lidModeInstalled: lidMode)
    }
    alert.informativeText = problem ?? ""
    problem = nil

    var actions: [() throws -> Void] = []
    func offer(_ title: String, _ action: @escaping () throws -> Void) {
        alert.addButton(withTitle: title)
        actions.append(action)
    }
    offer("Done") { exit(0) }
    if let network = snapshot?.network {
        if prefs.homes.contains(network) {
            offer("Forget this home network") { try updatePrefs { $0.homes.remove(network) } }
        } else {
            offer("Use this network as home") { try updatePrefs { $0.homes.insert(network) } }
        }
    }
    offer(prefs.enabled ? "Pause" : "Resume") { try updatePrefs { $0.enabled.toggle() } }
    if !lidMode { offer("Set up lid-closed mode…", setUpLidMode) }
    offer("Remove HomeAwake") { remove(); exit(0) }
    alert.buttons.last?.hasDestructiveAction = true

    let choice = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    do { try actions[choice]() } catch { problem = error.localizedDescription }
}
