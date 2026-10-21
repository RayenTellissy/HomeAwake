import Foundation
import HomeAwakeCore
import IOKit.ps
import IOKit.pwr_mgt
import notify
import SystemConfiguration

// Swift does not import the iokit_common_msg() macros behind these message types.
let canSystemSleep: UInt32 = 0xE000_0270
let systemWillSleep: UInt32 = 0xE000_0280
let systemHasPoweredOn: UInt32 = 0xE000_0300

let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
let ipv4Key = "State:/Network/Global/IPv4" as CFString
let store = SCDynamicStoreCreate(nil, "homeawake-agent" as CFString, { _, _, _ in reconcile() }, nil)!
var assertion: IOPMAssertionID?
var arpRetry: DispatchWorkItem?
var ownsSleepSwitch = load(AgentStatus.self, from: Files.status)?.ownsSleepSwitch ?? false
var observed: Snapshot?

func rootDomainFlag(_ key: String) -> Bool {
    IORegistryEntryCreateCFProperty(rootDomain, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
        ?? false
}

@discardableResult
func sudo(_ command: [String]) -> Bool {
    let ok = run(["/usr/bin/sudo", "-n"] + command).ok
    if !ok { NSLog("sudo -n %@ failed", command.joined(separator: " ")) }
    return ok
}

/// Converges the system on one decision. It compares against the real state every time, so repeating it changes
/// nothing.
func apply(stayAwake: Bool, lidClosed: Bool, terminating: Bool = false) {
    if stayAwake, assertion == nil {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Reachable at home for remote sessions" as CFString,
            &id
        )
        if result == kIOReturnSuccess { assertion = id } else { NSLog("Sleep assertion failed: %d", result) }
    } else if !stayAwake, let id = assertion {
        IOPMAssertionRelease(id)
        assertion = nil
    }
    let plan = planSleepSwitch(stayAwake: stayAwake, sleepDisabled: rootDomainFlag("SleepDisabled"),
                               owned: ownsSleepSwitch, canWrite: lidModeInstalled(), lidClosed: lidClosed,
                               terminating: terminating)
    if let value = plan.write, !sudo(value ? Pmset.preventSleep : Pmset.allowSleep) { return }
    ownsSleepSwitch = plan.owned
    if plan.sleepNow { sleepNow() }
}

func sleepNow() {
    let powerManagement = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
    defer { IOServiceClose(powerManagement) }
    let result = IOPMSleepSystem(powerManagement)
    if result != kIOReturnSuccess { NSLog("Sleep request failed: %d", result) }
}

func saveStatus() {
    guard let observed else { return }
    do { try save(AgentStatus(snapshot: observed, ownsSleepSwitch: ownsSleepSwitch), to: Files.status) } catch {
        NSLog("Could not write status: %@", "\(error)")
    }
}

func reconcile(arpAttempt: Int = 0) {
    arpRetry?.cancel()
    let router = (SCDynamicStoreCopyValue(store, ipv4Key) as? [String: Any])?["Router"] as? String
    let network = router.flatMap { NetworkID(arpOutput: run(["/usr/sbin/arp", "-n", $0]).output) }
    // The time-remaining estimate can still read battery when the kIOPSNotifyPowerSource post arrives.
    let providing = IOPSGetProvidingPowerSourceType(IOPSCopyPowerSourcesInfo().takeRetainedValue())
    let power: PowerSource = providing?.takeUnretainedValue() as String? == kIOPMACPowerKey ? .ac : .battery
    let snapshot = Snapshot(power: power, network: network, lidClosed: rootDomainFlag("AppleClamshellState"))
    let prefs = load(Prefs.self, from: Files.prefs) ?? Prefs()
    observed = snapshot
    apply(stayAwake: decide(snapshot, prefs) == .stayAwake, lidClosed: snapshot.lidClosed)
    saveStatus()
    // A network that just came up often has a router before the router has an ARP entry.
    if router != nil, network == nil, arpAttempt < 4 {
        let retry = DispatchWorkItem { reconcile(arpAttempt: arpAttempt + 1) }
        arpRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2 << arpAttempt), execute: retry)
    }
}

SCDynamicStoreSetNotificationKeys(store, [ipv4Key] as CFArray, nil)
SCDynamicStoreSetDispatchQueue(store, .main)

// kIOPSNotifyPowerSource fires only on AC/battery switches. IOPSNotificationCreateRunLoopSource also fires on every
// battery percentage change.
var token = Int32(0)
notify_register_dispatch(kIOPSNotifyPowerSource, &token, .main) { _ in reconcile() }
notify_register_dispatch(prefsChanged, &token, .main) { _ in reconcile() }

var rootPort = io_connect_t(0)
var powerPort: IONotificationPortRef?
var powerNotifier = io_object_t(0)
rootPort = IORegisterForSystemPower(nil, &powerPort, { _, _, message, argument in
    switch message {
    case canSystemSleep, systemWillSleep: IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case systemHasPoweredOn: reconcile()
    default: break
    }
}, &powerNotifier)
IONotificationPortSetDispatchQueue(powerPort, .main)

signal(SIGTERM, SIG_IGN)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminate.setEventHandler {
    // Logout and shutdown send SIGTERM too, and a forced sleep then would cut off a remote restart.
    apply(stayAwake: false, lidClosed: false, terminating: true)
    saveStatus()
    exit(0)
}
terminate.resume()

reconcile()
dispatchMain()
