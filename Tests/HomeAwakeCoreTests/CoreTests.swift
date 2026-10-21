import Foundation
import HomeAwakeCore
import Testing

let home = NetworkID(mac: "c4:0f:5e:10:07:c0")!
let cafe = NetworkID(mac: "00:11:22:33:44:55")!

@Test func decideChecksReasonsInOrder() {
    let homeOnly = Prefs(homes: [home]), paused = Prefs(enabled: false, homes: [home])
    let rows: [(PowerSource, NetworkID?, Prefs, Decision)] = [
        (.ac, home, homeOnly, .stayAwake),
        (.ac, home, paused, .allowSleep(.paused)),
        (.battery, home, paused, .allowSleep(.paused)),
        (.battery, home, homeOnly, .allowSleep(.onBattery)),
        (.battery, nil, homeOnly, .allowSleep(.onBattery)),
        (.ac, nil, homeOnly, .hold),
        (.ac, nil, paused, .allowSleep(.paused)),
        (.ac, cafe, homeOnly, .allowSleep(.notHome)),
        (.ac, home, Prefs(), .allowSleep(.notHome)),
    ]
    for (power, network, prefs, decision) in rows {
        #expect(decide(Snapshot(power: power, network: network), prefs) == decision,
                "\(power) \(String(describing: network)) \(prefs)")
    }
}

@Test func macNormalization() {
    #expect(NetworkID(mac: "C4:F:5e:10:7:C0")?.gatewayMAC == "c4:0f:5e:10:07:c0")
    #expect(NetworkID(mac: "0:0:0:0:0:0")?.gatewayMAC == "00:00:00:00:00:00")
    for bad in ["c4:f:5e:10:7", "c4:f:5e:10:7:c0:1", "c4::5e:10:7:c0", "c4:f:5e:10:7:c00", "c4:f:5e:10:7:g0",
                "c4:f:5e:10:7:c０"] {
        #expect(NetworkID(mac: bad) == nil, "\(bad)")
    }
}

@Test func arpOutputParsing() {
    let found = "? (192.168.1.254) at c4:f:5e:10:7:c0 on en0 ifscope [ethernet]\n"
    #expect(NetworkID(arpOutput: found)?.gatewayMAC == "c4:0f:5e:10:07:c0")
    #expect(NetworkID(arpOutput: "? (192.168.1.254) at (incomplete) on en0 ifscope [ethernet]\n") == nil)
    #expect(NetworkID(arpOutput: "192.168.1.77 (192.168.1.77) -- no entry\n") == nil)
    let secondLine = "? (10.0.0.1) at (incomplete) on en1 ifscope [ethernet]\n? (10.0.0.1) at a:b:c:d:e:f on en0\n"
    #expect(NetworkID(arpOutput: secondLine)?.gatewayMAC == "0a:0b:0c:0d:0e:0f")
}

/// A path in a directory that does not exist yet, removed afterwards.
func withScratchFile(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "homeawake-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory.appending(path: "file.json"))
}

@Test func prefsFileRoundTrip() throws {
    try withScratchFile { url in
        try save(Prefs(enabled: false, homes: [home]), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == """
            {
              "enabled" : false,
              "homes" : [
                "c4:0f:5e:10:07:c0"
              ]
            }
            """)

        try Data(#"{"enabled": true, "homes": ["C4:F:5e:10:7:C0"]}"#.utf8).write(to: url)
        #expect(load(Prefs.self, from: url) == Prefs(enabled: true, homes: [home]))

        try Data(#"{"enabled": true, "homes": ["not a mac"]}"#.utf8).write(to: url)
        #expect(load(Prefs.self, from: url) == nil)
    }
}

@Test func saveSkipsUnchangedContent() throws {
    try withScratchFile { url in
        let old = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = Snapshot(power: .ac, network: home)

        try save(snapshot, to: url)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        try save(snapshot, to: url)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == old)
        #expect(try writeIfChanged(Data(contentsOf: url), to: url) == false)

        #expect(try writeIfChanged(Data(#"{"power":"battery"}"#.utf8), to: url) == true)
        #expect(load(Snapshot.self, from: url) == Snapshot(power: .battery, network: nil))
    }
}

@Test func statusFileText() throws {
    try withScratchFile { url in
        let status = AgentStatus(snapshot: Snapshot(power: .ac, network: home), ownsSleepSwitch: true)
        try save(status, to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == """
            {
              "ownsSleepSwitch" : true,
              "snapshot" : {
                "network" : "c4:0f:5e:10:07:c0",
                "power" : "ac"
              }
            }
            """)
        #expect(load(AgentStatus.self, from: url) == status)

        try Data(#"{"ownsSleepSwitch": true, "snapshot": {"power": "ac", "lidClosed": true}}"#.utf8).write(to: url)
        #expect(load(AgentStatus.self, from: url)
            == AgentStatus(snapshot: Snapshot(power: .ac, network: nil), ownsSleepSwitch: true))

        try Data(#"{"power": "ac"}"#.utf8).write(to: url)
        #expect(load(AgentStatus.self, from: url) == nil)
    }
}

@Test func sudoersRuleText() {
    #expect(sudoersRule(user: "ryan")
        == "ryan ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1")
    for bad in ["", "a b", "x;rm", "it's", "%admin"] {
        #expect(sudoersRule(user: bad) == nil, "\(bad)")
    }
}

@Test func installScriptText() {
    #expect(installScript(user: "ryan") == #"""
        do shell script "t=$(/usr/bin/mktemp) && /usr/bin/printf '%s\\n' 'ryan ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1' > \"$t\" && /usr/sbin/visudo -cf \"$t\" && /usr/bin/install -S -m 0440 -o root -g wheel \"$t\" /etc/sudoers.d/homeawake; s=$?; /bin/rm -f \"$t\"; exit $s" with administrator privileges
        """#)
    #expect(installScript(user: "a b") == nil)
}

@Test func launchAgentPlistText() throws {
    let plist = try launchAgentPlist(agentPath: "/Users/a&b/HomeAwake.app/Contents/MacOS/homeawake-agent")
    #expect(String(decoding: plist, as: UTF8.self) == """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>KeepAlive</key>
        \t<true/>
        \t<key>Label</key>
        \t<string>dev.homeawake.agent</string>
        \t<key>ProcessType</key>
        \t<string>Background</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>/Users/a&amp;b/HomeAwake.app/Contents/MacOS/homeawake-agent</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        </dict>
        </plist>

        """)
}

@Test func statusLineText() {
    #expect(statusLine(.stayAwake, sleepDisabled: true) == "Awake at home, even with the lid closed.")
    #expect(statusLine(.stayAwake, sleepDisabled: false)
        == "Awake at home while the lid is open. Closing the lid still sleeps.")
    #expect(statusLine(.allowSleep(.notHome), sleepDisabled: true) == "Not on a home network. This Mac sleeps normally.")
    #expect(statusLine(.hold, sleepDisabled: true)
        == "No network right now. HomeAwake keeps the Mac as it was until the network is back.")
    let decisions: [Decision] = [.stayAwake, .allowSleep(.paused), .allowSleep(.onBattery), .allowSleep(.notHome),
                                 .hold]
    #expect(Set(decisions.map { statusLine($0, sleepDisabled: false) }).count == decisions.count)
}

@Test func infoLineText() {
    #expect(infoLine(network: home, lidModeAvailable: true)
        == "This network's router is c4:0f:5e:10:07:c0. Lid-closed mode is available.")
    #expect(infoLine(network: nil, lidModeAvailable: false)
        == "No router found on this network. Lid-closed mode is not set up.")
}

@Test func runReportsExitStatusAndOutput() {
    #expect(run(["/bin/echo", "c4:f:a6"]) == (true, "c4:f:a6\n"))
    #expect(run(["/bin/sh", "-c", "echo partial; echo noise >&2; exit 3"]) == (false, "partial\n"))
    #expect(run(["/nonexistent/tool"]) == (false, ""))
    #expect(run(["/bin/sh", "-c", "/usr/bin/yes | /usr/bin/head -c 200000"]).output.count == 200_000)
}

let sudoListHeader = """
    Matching Defaults entries for ryan on mac:
        env_reset, env_keep+=BLOCKSIZE, env_keep+="COLORFGBG COLORTERM",
        env_keep+=__CF_USER_TEXT_ENCODING

    User ryan may run the following commands on mac:
        (ALL) ALL

    """

@Test func lidModeFromAnotherToolsSeparateLines() {
    let insomnia = """
            (root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
            (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
            (root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1
            (root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0

        """
    #expect(grantsLidMode(sudoList: sudoListHeader + insomnia))
}

@Test func lidModeFromOneCommaJoinedRule() {
    let rule = "    (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
    #expect(grantsLidMode(sudoList: sudoListHeader + rule))
}

@Test func noLidModeWithoutBothPasswordlessCommands() {
    #expect(!grantsLidMode(sudoList: sudoListHeader + "    (root) NOPASSWD: /usr/bin/pmset -a disablesleep 1\n"))
    #expect(!grantsLidMode(sudoList: sudoListHeader + """
            (root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
            (root) /usr/bin/pmset -a disablesleep 0

        """))
    #expect(!grantsLidMode(sudoList: sudoListHeader))
}

func plan(stayAwake: Bool, on: Bool, owned: Bool, canWrite: Bool = true) -> SleepSwitchPlan {
    planSleepSwitch(stayAwake: stayAwake, sleepDisabled: on, owned: owned, canWrite: canWrite)
}

@Test func stayAwakeTurnsTheSwitchOnAndTakesOwnership() {
    #expect(plan(stayAwake: true, on: false, owned: false) == SleepSwitchPlan(write: true, owned: true))
    #expect(plan(stayAwake: true, on: false, owned: true) == SleepSwitchPlan(write: true, owned: true))
}

@Test func stayAwakeLeavesAnotherToolsSwitchWithThatTool() {
    #expect(plan(stayAwake: true, on: true, owned: false) == SleepSwitchPlan(write: nil, owned: false))
    #expect(plan(stayAwake: true, on: true, owned: true) == SleepSwitchPlan(write: nil, owned: true))
}

@Test func allowSleepTurnsOffOnlyItsOwnSwitch() {
    #expect(plan(stayAwake: false, on: true, owned: true) == SleepSwitchPlan(write: false, owned: false))
    #expect(plan(stayAwake: false, on: true, owned: false) == SleepSwitchPlan(write: nil, owned: false))
}

@Test func allowSleepDropsOwnershipOfASwitchThatIsAlreadyOff() {
    #expect(plan(stayAwake: false, on: false, owned: true) == SleepSwitchPlan(write: nil, owned: false))
}

@Test func withoutARuleNothingTurnsTheSwitchOnButReleasingStillTries() {
    #expect(plan(stayAwake: true, on: false, owned: false, canWrite: false) == SleepSwitchPlan(write: nil, owned: false))
    #expect(plan(stayAwake: true, on: false, owned: true, canWrite: false) == SleepSwitchPlan(write: nil, owned: true))
    #expect(plan(stayAwake: false, on: true, owned: true, canWrite: false)
        == SleepSwitchPlan(write: false, owned: false))
}

@Test func checksTheRuleOnlyBeforeTurningTheSwitchOn() {
    var checks = 0
    func canWrite() -> Bool { checks += 1; return true }
    let rows = [(true, true, false), (false, true, true), (false, true, false), (false, false, true)]
    for (stayAwake, on, owned) in rows {
        _ = planSleepSwitch(stayAwake: stayAwake, sleepDisabled: on, owned: owned, canWrite: canWrite())
    }
    #expect(checks == 0)
    _ = planSleepSwitch(stayAwake: true, sleepDisabled: false, owned: false, canWrite: canWrite())
    #expect(checks == 1)
}

func menu(_ decision: Decision?, running: Bool = true, switchOn: Bool = false, network: NetworkID? = home,
          isHome: Bool = true, enabled: Bool = true, lidMode: Bool = true) -> MenuState {
    MenuState(decision: decision, agentRunning: running, sleepDisabled: switchOn, network: network, isHome: isHome,
              enabled: enabled, lidModeAvailable: lidMode)
}

let menuFooter: [MenuRow] = [.separator, .action("Hide menu bar icon", .hideIcon), .action("Remove HomeAwake", .remove)]
let homeInfo = MenuRow.info("This network's router is c4:0f:5e:10:07:c0. Lid-closed mode is available.")

@Test func menuBeforeTheAgentWritesStatus() {
    let s = menu(nil)
    #expect(menuRows(s) == [.info("HomeAwake is starting."), homeInfo, .separator,
                            .action("Forget this home network", .forgetHome(home)), .action("Pause", .pause)]
        + menuFooter)
    #expect(iconSymbol(s) == "moon.zzz")
}

@Test func menuWhenTheAgentIsNotRunning() {
    let s = menu(.stayAwake, running: false, switchOn: true)
    #expect(menuRows(s) == [.info("The HomeAwake agent is not running."), homeInfo, .separator,
                            .action("Forget this home network", .forgetHome(home)), .action("Pause", .pause)]
        + menuFooter)
    #expect(iconSymbol(s) == "moon.zzz")
}

@Test func menuAwakeAtHomeWithTheSwitchOn() {
    let s = menu(.stayAwake, switchOn: true)
    #expect(menuRows(s) == [.info("Awake at home, even with the lid closed."), homeInfo, .separator,
                            .action("Forget this home network", .forgetHome(home)), .action("Pause", .pause)]
        + menuFooter)
    #expect(iconSymbol(s) == "sun.max.fill")
}

@Test func menuAwakeAtHomeWithTheSwitchOffAndNoLidMode() {
    let s = menu(.stayAwake, lidMode: false)
    #expect(menuRows(s) == [
        .info("Awake at home while the lid is open. Closing the lid still sleeps."),
        .info("This network's router is c4:0f:5e:10:07:c0. Lid-closed mode is not set up."), .separator,
        .action("Forget this home network", .forgetHome(home)), .action("Pause", .pause),
        .action("Set up lid-closed mode…", .setUpLidMode),
    ] + menuFooter)
    #expect(iconSymbol(s) == "sun.max")
}

@Test func menuOnANetworkThatIsNotHome() {
    let s = menu(.allowSleep(.notHome), network: cafe, isHome: false)
    #expect(menuRows(s) == [
        .info("Not on a home network. This Mac sleeps normally."),
        .info("This network's router is 00:11:22:33:44:55. Lid-closed mode is available."), .separator,
        .action("Use this network as home", .useAsHome(cafe)), .action("Pause", .pause),
    ] + menuFooter)
    #expect(iconSymbol(s) == "moon.zzz")
}

@Test func menuWhilePaused() {
    let s = menu(.allowSleep(.paused), enabled: false)
    #expect(menuRows(s) == [.info("Paused. This Mac sleeps normally."), homeInfo, .separator,
                            .action("Forget this home network", .forgetHome(home)), .action("Resume", .resume)]
        + menuFooter)
    #expect(iconSymbol(s) == "moon.zzz")
}

@Test func menuOnBattery() {
    let s = menu(.allowSleep(.onBattery), switchOn: true)
    #expect(menuRows(s) == [.info("On battery. This Mac sleeps normally."), homeInfo, .separator,
                            .action("Forget this home network", .forgetHome(home)), .action("Pause", .pause)]
        + menuFooter)
    #expect(iconSymbol(s) == "moon.zzz")
}

@Test func menuHoldingWithNoNetwork() {
    let s = menu(.hold, switchOn: true, network: nil, isHome: false)
    #expect(menuRows(s) == [
        .info("No network right now. HomeAwake keeps the Mac as it was until the network is back."),
        .info("No router found on this network. Lid-closed mode is available."), .separator,
        .action("Pause", .pause),
    ] + menuFooter)
    #expect(iconSymbol(s) == "wifi.slash")
}

@Test func menuPausedWithNoNetworkAndNoLidMode() {
    let s = menu(.allowSleep(.paused), network: nil, isHome: false, enabled: false, lidMode: false)
    #expect(menuRows(s) == [
        .info("Paused. This Mac sleeps normally."),
        .info("No router found on this network. Lid-closed mode is not set up."), .separator,
        .action("Resume", .resume), .action("Set up lid-closed mode…", .setUpLidMode),
    ] + menuFooter)
    #expect(iconSymbol(s) == "moon.zzz")
}
