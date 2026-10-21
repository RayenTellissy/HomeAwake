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

let store = SCDynamicStoreCreate(nil, "homeawake-agent" as CFString, { _, _, _ in reconcile() }, nil)!
let arpRetry = DispatchSource.makeTimerSource(queue: .main)
var assertion: IOPMAssertionID?
var ownsSleepSwitch = load(AgentStatus.self, from: Files.status)?.ownsSleepSwitch ?? false
var observed: Snapshot?
/// A denied `sudo -n -l` holds until the next reconcile request, so the events in between spawn no sudo.
var sudoDenied = false

func sudoAllowsLidMode() -> Bool {
    if !sudoDenied { sudoDenied = !sudoGrantsLidMode() }
    return !sudoDenied
}

/// True when it just turned off the switch HomeAwake owned.
@discardableResult
func apply(stayAwake: Bool) -> Bool {
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
    let update = updateSleepSwitch(stayAwake: stayAwake, owned: ownsSleepSwitch, canWrite: sudoAllowsLidMode())
    ownsSleepSwitch = update.owned
    return update.released
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
    let prefs = load(Prefs.self, from: Files.prefs) ?? Prefs()
    let providing = IOPSGetProvidingPowerSourceType(IOPSCopyPowerSourcesInfo().takeRetainedValue())
    let power: PowerSource = providing?.takeUnretainedValue() as String? == kIOPMACPowerKey ? .ac : .battery
    // Only a decision that would hold without a network can change once the network is known. Paused and on battery
    // decide without it, so they spawn no arp.
    let router = decide(Snapshot(power: power, network: nil), prefs) == .hold ? lookUpRouter(store) : nil
    let snapshot = Snapshot(power: power, network: router?.network)
    observed = snapshot
    switch decide(snapshot, prefs) {
    case .hold: break
    case .stayAwake: apply(stayAwake: true)
    case .allowSleep(let reason):
        let released = apply(stayAwake: false)
        // So a Mac unplugged with the lid shut does not stay awake in a bag.
        if released, reason == .onBattery, rootDomainFlag(kAppleClamshellStateKey) { sleepNow() }
    }
    saveStatus()
    if let router, router.network == nil, arpAttempt < 4 {
        arpRetry.setEventHandler { reconcile(arpAttempt: arpAttempt + 1) }
        arpRetry.schedule(deadline: .now() + .seconds(2 << arpAttempt))
    } else {
        arpRetry.schedule(deadline: .distantFuture)
    }
}

arpRetry.activate()
SCDynamicStoreSetNotificationKeys(store, [routerKey()] as CFArray, nil)
SCDynamicStoreSetDispatchQueue(store, .main)

var token = Int32(0)
// IOPSNotificationCreateRunLoopSource would also fire on every battery percentage change.
notify_register_dispatch(kIOPSNotifyPowerSource, &token, .main) { _ in reconcile() }
notify_register_dispatch(reconcileRequested, &token, .main) { _ in
    sudoDenied = false
    reconcile()
}

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
    // No forced sleep here. launchd also sends SIGTERM at logout and shutdown, and a sleep then would cut off a remote
    // restart.
    apply(stayAwake: false)
    saveStatus()
    exit(0)
}
terminate.resume()

reconcile()
dispatchMain()
