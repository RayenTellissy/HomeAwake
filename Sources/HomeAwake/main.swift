import AppKit
import HomeAwakeCore
import notify

struct Failure: LocalizedError { var errorDescription: String? }

func service(_ agent: LaunchAgent) -> String { "gui/\(getuid())/\(agent.rawValue)" }

func launchdJob(_ agent: LaunchAgent) -> (loaded: Bool, pid: Int32?) {
    let print = run(["/bin/launchctl", "print", service(agent)])
    return (print.ok, launchdPID(print: print.output))
}

/// True when it loaded the job, which RunAtLoad then starts.
func ensureInstalled(_ agent: LaunchAgent) throws -> Bool {
    guard let executable = Bundle.main.url(forAuxiliaryExecutable: agent.executable) else {
        throw Failure(errorDescription: "\(agent.executable) is missing from the app.")
    }
    let changed = try writeIfChanged(launchAgentPlist(agent, executablePath: executable.path), to: agent.plistFile)
    let loaded = launchdJob(agent).loaded
    guard changed || !loaded else { return false }
    if loaded { run(["/bin/launchctl", "bootout", service(agent)]) }
    guard run(["/bin/launchctl", "bootstrap", "gui/\(getuid())", agent.plistFile.path]).ok else {
        throw Failure(errorDescription: "launchctl could not load \(agent.rawValue).")
    }
    return true
}

/// Deletes the plist first, because booting out the menu app ends this process.
func uninstall(_ agent: LaunchAgent) {
    try? FileManager.default.removeItem(at: agent.plistFile)
    run(["/bin/launchctl", "bootout", service(agent)])
}

func updatePrefs(_ change: (inout Prefs) -> Void) throws {
    var prefs = load(Prefs.self, from: Files.prefs) ?? Prefs()
    change(&prefs)
    try save(prefs, to: Files.prefs)
    requestReconcile()
}

/// The agent applies a request after this returns, so wait briefly for its new status before redrawing.
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
    uninstall(.agent)
    if var status = load(AgentStatus.self, from: Files.status), status.ownsSleepSwitch {
        status.ownsSleepSwitch = updateSleepSwitch(stayAwake: false, owned: true).owned
        _ = try? save(status, to: Files.status)
    }
    uninstall(.menu)
}

func carryOut(_ action: MenuAction) throws {
    switch action {
    case .start: if try ensureInstalled(.agent) { requestReconcile() }
    case .useAsHome(let network): try updatePrefs { $0.homes.insert(network) }
    case .forgetHome(let network): try updatePrefs { $0.homes.remove(network) }
    case .pause: try updatePrefs { $0.enabled = false }
    case .resume: try updatePrefs { $0.enabled = true }
    case .setUpLidMode: try setUpLidMode()
    case .hideIcon: uninstall(.menu); exit(0)
    case .quit: remove(); exit(0)
    }
}

@MainActor func showAlert(_ message: String) {
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = message
    alert.runModal()
}

@MainActor final class StatusMenu: NSObject, NSMenuDelegate, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var lidModeAvailable = false

    override init() {
        super.init()
        item.menu = NSMenu()
        item.menu?.delegate = self
        showIcon(state(lookUp: false))
    }

    /// Without `lookUp` it spawns no arp or sudo, takes the network from the agent's status, and keeps the last known
    /// lid-closed mode. The icon needs nothing more.
    func state(lookUp: Bool) -> MenuState {
        let prefs = HomeAwakeCore.load(Prefs.self, from: Files.prefs) ?? Prefs()
        let status = HomeAwakeCore.load(AgentStatus.self, from: Files.status)
        // The agent skips the lookup while paused or on battery, so its snapshot can lack the network found here.
        let network = lookUp ? lookUpRouter()?.network : status?.snapshot.network
        if lookUp { lidModeAvailable = sudoGrantsLidMode() }
        return MenuState(
            decision: status.map { decide(Snapshot(power: $0.snapshot.power, network: network), prefs) },
            agentRunning: launchdJob(.agent).pid != nil, sleepDisabled: rootDomainFlag("SleepDisabled"),
            network: network, isHome: network.map(prefs.homes.contains) ?? false, enabled: prefs.enabled,
            lidModeAvailable: lidModeAvailable)
    }

    func showIcon(_ state: MenuState) {
        item.button?.image = NSImage(systemSymbolName: iconSymbol(state), accessibilityDescription: "HomeAwake")
    }

    func openMenu() { item.button?.performClick(nil) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // The agent remembers a denied sudo rule until a reconcile request, so this picks up a rule another tool
        // installed.
        notify_post(reconcileRequested)
        let state = state(lookUp: true)
        showIcon(state)
        menu.items = menuRows(state).map { row in
            switch row {
            case .separator: return .separator()
            case .headline(let headline): return headlineItem(headline, symbol: iconSymbol(state))
            case .action(let title, let action): return actionItem(title, action)
            case .toggle(let title, let isOn, let action):
                let item = actionItem(title, action)
                item.state = isOn ? .on : .off
                return item
            }
        }
    }

    func actionItem(_ title: String, _ action: MenuAction) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        return item
    }

    /// A view instead of a plain item, because AppKit greys out every item that has no action.
    func headlineItem(_ headline: Headline, symbol: String) -> NSMenuItem {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        image.contentTintColor = headline.awake ? .systemOrange : .secondaryLabelColor
        let title = NSTextField(labelWithString: headline.title)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let detail = NSTextField(wrappingLabelWithString: headline.detail)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 230
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [image, text])
        row.alignment = .top
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        row.frame.size = row.fittingSize
        let item = NSMenuItem()
        item.view = row
        return item
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuAction else { return }
        do { try carryOut(action) } catch { showAlert(error.localizedDescription) }
        showIcon(state(lookUp: false))
    }

    /// Opening the app while this instance runs can reach it as a reopen event instead of a second process.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openMenu()
        return false
    }
}

_ = NSApplication.shared
var readyToken = Int32(0), ready = Int32(0)
notify_register_check(menuReady, &readyToken)
// The first check after registering always reports a post.
notify_check(readyToken, &ready)

if launchdJob(.menu).pid != getpid() {
    do {
        if try ensureInstalled(.agent) {
            for _ in 0..<20 where !FileManager.default.fileExists(atPath: Files.status.path) { usleep(100_000) }
        }
        if try ensureInstalled(.menu) {
            ready = 0
            for _ in 0..<30 where ready == 0 { usleep(100_000); notify_check(readyToken, &ready) }
        }
        notify_post(menuRequested)
    } catch {
        showAlert(error.localizedDescription)
    }
    exit(0)
}

let menu = StatusMenu()
NSApp.delegate = menu
var token = Int32(0)
notify_register_dispatch(statusChanged, &token, .main) { _ in
    MainActor.assumeIsolated { menu.showIcon(menu.state(lookUp: false)) }
}
notify_register_dispatch(menuRequested, &token, .main) { _ in MainActor.assumeIsolated { menu.openMenu() } }
notify_post(menuReady)
NSApp.run()
