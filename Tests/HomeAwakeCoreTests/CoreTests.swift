import Foundation
import HomeAwakeCore
import Testing

let home = NetworkID(mac: "c4:0f:5e:10:07:c0")!
let cafe = NetworkID(mac: "00:11:22:33:44:55")!

@Test func decideChecksReasonsInOrder() {
    let atHome = Snapshot(power: .ac, network: home, lidClosed: true)
    #expect(decide(atHome, Prefs(homes: [home])) == .stayAwake)
    #expect(decide(atHome, Prefs(enabled: false, homes: [home])) == .allowSleep(.paused))
    #expect(decide(Snapshot(power: .battery, network: home, lidClosed: true), Prefs(enabled: false)) == .allowSleep(.paused))
    #expect(decide(Snapshot(power: .battery, network: nil, lidClosed: false), Prefs(homes: [home])) == .allowSleep(.onBattery))
    #expect(decide(Snapshot(power: .ac, network: nil, lidClosed: false), Prefs(homes: [home])) == .allowSleep(.offline))
    #expect(decide(Snapshot(power: .ac, network: cafe, lidClosed: false), Prefs(homes: [home])) == .allowSleep(.notHome))
    #expect(decide(atHome, Prefs()) == .allowSleep(.notHome))
}

@Test func macNormalization() {
    #expect(NetworkID(mac: "C4:F:5e:10:7:C0")?.gatewayMAC == "c4:0f:5e:10:07:c0")
    #expect(NetworkID(mac: "0:0:0:0:0:0")?.gatewayMAC == "00:00:00:00:00:00")
    for bad in ["c4:f:5e:10:7", "c4:f:5e:10:7:c0:1", "c4::5e:10:7:c0", "c4:f:5e:10:7:c00", "c4:f:5e:10:7:g0",
                "c4:f:5e:10:7:c０", "(incomplete)", ""] {
        #expect(NetworkID(mac: bad) == nil, "\(bad)")
    }
}

@Test func arpOutputParsing() {
    let found = "? (192.168.1.254) at c4:f:5e:10:7:c0 on en0 ifscope [ethernet]\n"
    #expect(NetworkID(arpOutput: found)?.gatewayMAC == "c4:0f:5e:10:07:c0")
    #expect(NetworkID(arpOutput: "? (192.168.1.254) at (incomplete) on en0 ifscope [ethernet]\n") == nil)
    #expect(NetworkID(arpOutput: "192.168.1.77 (192.168.1.77) -- no entry\n") == nil)
    #expect(NetworkID(arpOutput: "") == nil)
    let secondLine = "? (10.0.0.1) at (incomplete) on en1 ifscope [ethernet]\n? (10.0.0.1) at a:b:c:d:e:f on en0\n"
    #expect(NetworkID(arpOutput: secondLine)?.gatewayMAC == "0a:0b:0c:0d:0e:0f")
}

@Test func prefsFileRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "homeawake-\(UUID())/prefs.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

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

@Test func saveSkipsUnchangedContent() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "homeawake-\(UUID())/status.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let old = Date(timeIntervalSince1970: 1_000_000)
    let snapshot = Snapshot(power: .ac, network: home, lidClosed: false)
    func modified() throws -> Date? { try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date }

    try save(snapshot, to: url)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    try save(snapshot, to: url)
    #expect(try modified() == old)

    try save(Snapshot(power: .battery, network: nil, lidClosed: true), to: url)
    #expect(load(Snapshot.self, from: url) == Snapshot(power: .battery, network: nil, lidClosed: true))
    #expect(try modified() != old)
}

@Test func statusFileText() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "homeawake-\(UUID())/status.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let status = AgentStatus(snapshot: Snapshot(power: .ac, network: home, lidClosed: true), ownsSleepSwitch: true)
    try save(status, to: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == """
        {
          "ownsSleepSwitch" : true,
          "snapshot" : {
            "lidClosed" : true,
            "network" : "c4:0f:5e:10:07:c0",
            "power" : "ac"
          }
        }
        """)
    #expect(load(AgentStatus.self, from: url) == status)

    try Data(#"{"power": "ac", "lidClosed": false}"#.utf8).write(to: url)
    #expect(load(AgentStatus.self, from: url) == nil)
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

@Test func launchAgentPlistText() {
    let plist = launchAgentPlist(agentPath: "/Users/a&b/HomeAwake.app/Contents/MacOS/homeawake-agent")
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
    #expect(statusLine(.stayAwake, lidModeAvailable: true) == "Awake at home, even with the lid closed.")
    #expect(statusLine(.stayAwake, lidModeAvailable: false)
        == "Awake at home while the lid is open. Closing the lid still sleeps.")
    #expect(statusLine(.allowSleep(.notHome), lidModeAvailable: true) == "Not on a home network. This Mac sleeps normally.")
    let decisions: [Decision] = [.stayAwake, .allowSleep(.paused), .allowSleep(.onBattery), .allowSleep(.offline),
                                 .allowSleep(.notHome)]
    #expect(Set(decisions.map { statusLine($0, lidModeAvailable: false) }).count == decisions.count)
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
    let unwrapped = "    (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
    #expect(grantsLidMode(sudoList: sudoListHeader + unwrapped))
    let wrapped = """
            (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a
                disablesleep 1

        """
    #expect(grantsLidMode(sudoList: sudoListHeader + wrapped))
}

@Test func noLidModeWithoutBothPasswordlessCommands() {
    #expect(!grantsLidMode(sudoList: sudoListHeader + "    (root) NOPASSWD: /usr/bin/pmset -a disablesleep 1\n"))
    #expect(!grantsLidMode(sudoList: sudoListHeader + """
            (root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
            (root) /usr/bin/pmset -a disablesleep 0

        """))
    #expect(!grantsLidMode(sudoList: sudoListHeader + """
            (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a
        disablesleep 1

        """))
    #expect(!grantsLidMode(sudoList: sudoListHeader))
    #expect(!grantsLidMode(sudoList: ""))
}

func plan(stayAwake: Bool, on: Bool, owned: Bool, canWrite: Bool = true, lidClosed: Bool = false,
          terminating: Bool = false) -> SleepSwitchPlan {
    planSleepSwitch(stayAwake: stayAwake, sleepDisabled: on, owned: owned, canWrite: canWrite, lidClosed: lidClosed,
                    terminating: terminating)
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
    #expect(plan(stayAwake: false, on: true, owned: false, lidClosed: true) == SleepSwitchPlan(write: nil, owned: false))
}

@Test func allowSleepDropsOwnershipOfASwitchThatIsAlreadyOff() {
    #expect(plan(stayAwake: false, on: false, owned: true) == SleepSwitchPlan(write: nil, owned: false))
    #expect(plan(stayAwake: false, on: false, owned: true, canWrite: false) == SleepSwitchPlan(write: nil, owned: false))
    #expect(plan(stayAwake: false, on: false, owned: false, lidClosed: true) == SleepSwitchPlan(write: nil, owned: false))
}

@Test func turningOwnSwitchOffWithTheLidClosedSleepsUnlessTerminating() {
    #expect(plan(stayAwake: false, on: true, owned: true, lidClosed: true)
        == SleepSwitchPlan(write: false, owned: false, sleepNow: true))
    #expect(plan(stayAwake: false, on: true, owned: true, lidClosed: true, terminating: true)
        == SleepSwitchPlan(write: false, owned: false, sleepNow: false))
}

@Test func withoutARuleNothingIsWrittenAndOwnershipStays() {
    #expect(plan(stayAwake: true, on: false, owned: false, canWrite: false) == SleepSwitchPlan(write: nil, owned: false))
    #expect(plan(stayAwake: true, on: false, owned: true, canWrite: false) == SleepSwitchPlan(write: nil, owned: true))
    #expect(plan(stayAwake: false, on: true, owned: true, canWrite: false, lidClosed: true)
        == SleepSwitchPlan(write: nil, owned: true))
}

@Test func checksTheRuleOnlyWhenAWriteIsDue() {
    var checks = 0
    func canWrite() -> Bool { checks += 1; return true }
    for (stayAwake, on, owned) in [(true, true, false), (true, true, true), (false, false, true), (false, true, false)] {
        _ = planSleepSwitch(stayAwake: stayAwake, sleepDisabled: on, owned: owned, canWrite: canWrite(),
                            lidClosed: true, terminating: false)
    }
    #expect(checks == 0)
    _ = planSleepSwitch(stayAwake: true, sleepDisabled: false, owned: false, canWrite: canWrite(), lidClosed: false,
                        terminating: false)
    _ = planSleepSwitch(stayAwake: false, sleepDisabled: true, owned: true, canWrite: canWrite(), lidClosed: false,
                        terminating: false)
    #expect(checks == 2)
}
