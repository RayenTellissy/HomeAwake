import AppKit
import HomeAwakeCore
import notify

struct Failure: LocalizedError { var errorDescription: String? }

let service = "gui/\(getuid())/\(agentLabel)"

func agentService() -> (loaded: Bool, running: Bool) {
    let print = run(["/bin/launchctl", "print", service])
    return (print.ok, print.output.contains("state = running"))
}

func ensureAgentInstalled() throws {
    guard let agent = Bundle.main.url(forAuxiliaryExecutable: "homeawake-agent") else {
        throw Failure(errorDescription: "The HomeAwake agent is missing from the app.")
    }
    let changed = try writeIfChanged(launchAgentPlist(agentPath: agent.path), to: Files.launchAgent)
    let loaded = agentService().loaded
    guard changed || !loaded else { return }
    if loaded { run(["/bin/launchctl", "bootout", service]) }
    guard run(["/bin/launchctl", "bootstrap", "gui/\(getuid())", Files.launchAgent.path]).ok else {
        throw Failure(errorDescription: "launchctl could not load the HomeAwake agent.")
    }
    for _ in 0..<20 where !FileManager.default.fileExists(atPath: Files.status.path) { usleep(100_000) }
}

func updatePrefs(_ change: (inout Prefs) -> Void) throws {
    var prefs = load(Prefs.self, from: Files.prefs) ?? Prefs()
    change(&prefs)
    try save(prefs, to: Files.prefs)
    requestReconcile()
}

/// The agent applies a request after this returns, so wait briefly for its new status before redrawing the window.
func requestReconcile() {
    let before = try? Data(contentsOf: Files.status)
    notify_post(reconcileRequested)
    for _ in 0..<10 where (try? Data(contentsOf: Files.status)) == before { usleep(100_000) }
}

func setUpLidMode() throws {
    guard let source = installScript(user: NSUserName()) else {
        throw Failure(errorDescription: "Your user name cannot go in a sudoers rule.")
    }
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error {
        guard error[NSAppleScript.errorNumber] as? Int != Int(userCanceledErr) else { return }
        throw Failure(errorDescription: error[NSAppleScript.errorMessage] as? String ?? "Setup failed.")
    }
    requestReconcile()
}

func remove() {
    run(["/bin/launchctl", "bootout", service])
    try? FileManager.default.removeItem(at: Files.launchAgent)
    guard var status = load(AgentStatus.self, from: Files.status), status.ownsSleepSwitch else { return }
    status.ownsSleepSwitch = updateSleepSwitch(stayAwake: false, owned: true).owned
    try? save(status, to: Files.status)
}

NSApplication.shared.setActivationPolicy(.regular)
NSApp.activate()

var problem: String?
do { try ensureAgentInstalled() } catch { problem = error.localizedDescription }
// The agent remembers a denied sudo rule until a reconcile request, so this picks up a rule another tool installed.
notify_post(reconcileRequested)

while true {
    let prefs = load(Prefs.self, from: Files.prefs) ?? Prefs()
    let snapshot = load(AgentStatus.self, from: Files.status)?.snapshot
    let network = lookUpRouter()?.network
    let lidMode = sudoGrantsLidMode()

    let alert = NSAlert()
    alert.messageText = switch (agentService().running, snapshot) {
    case (false, _): "The HomeAwake agent is not running."
    case (true, nil): "HomeAwake is starting."
    case let (true, snapshot?):
        // The agent skips the lookup while paused or on battery, so its snapshot can lack the network found here.
        statusLine(decide(Snapshot(power: snapshot.power, network: network), prefs),
                   sleepDisabled: rootDomainFlag("SleepDisabled"))
    }
    alert.informativeText = [problem, infoLine(network: network, lidModeAvailable: lidMode)]
        .compactMap { $0 }.joined(separator: "\n\n")
    problem = nil

    var actions: [() throws -> Void] = []
    func offer(_ title: String, _ action: @escaping () throws -> Void) {
        alert.addButton(withTitle: title)
        actions.append(action)
    }
    offer("Done") { exit(0) }
    if let network {
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
