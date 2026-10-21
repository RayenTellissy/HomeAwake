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
func apply(stayAwake: Bool, lidClosed: Bool) {
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
    guard rootDomainFlag("SleepDisabled") != stayAwake, lidModeInstalled() else { return }
    // Without the explicit sleep, a Mac unplugged with the lid shut stays awake in a bag.
    if sudo(stayAwake ? Pmset.preventSleep : Pmset.allowSleep), !stayAwake, lidClosed { sudo(Pmset.sleepNow) }
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
    apply(stayAwake: decide(snapshot, prefs) == .stayAwake, lidClosed: snapshot.lidClosed)
    do { try save(snapshot, to: Files.status) } catch { NSLog("Could not write status: %@", "\(error)") }
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
    apply(stayAwake: false, lidClosed: false)
    exit(0)
}
terminate.resume()

reconcile()
dispatchMain()
