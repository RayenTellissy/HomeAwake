public enum PowerSource: String, Codable, Sendable { case ac, battery }

/// A network, identified by its default gateway's MAC address. Every value is normalized: lowercase, two hex digits
/// per octet. It encodes as a bare string so prefs.json stays readable.
public struct NetworkID: Hashable, Codable, Sendable {
    public let gatewayMAC: String

    /// Accepts arp's spelling, which drops leading zeros per octet (`c4:f:5e:10:7:c0`).
    public init?(mac: some StringProtocol) {
        let octets = mac.lowercased().split(separator: ":", omittingEmptySubsequences: false)
        guard octets.count == 6,
              octets.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy { $0.isASCII && $0.isHexDigit } })
        else { return nil }
        gatewayMAC = octets.map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":")
    }

    /// Reads `arp -n <ip>` output: `? (192.168.1.254) at c4:f:5e:10:7:c0 on en0 ifscope [ethernet]`.
    /// Nil for `at (incomplete)` and `-- no entry`.
    public init?(arpOutput: String) {
        for line in arpOutput.split(separator: "\n") {
            let words = line.split(separator: " ")
            if let at = words.firstIndex(of: "at"), at + 1 < words.endIndex, let id = NetworkID(mac: words[at + 1]) {
                self = id
                return
            }
        }
        return nil
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = NetworkID(mac: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a MAC: \(raw)"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(gatewayMAC)
    }
}

/// What the agent last observed.
public struct Snapshot: Equatable, Codable, Sendable {
    public var power: PowerSource
    public var network: NetworkID?
    public var lidClosed: Bool

    public init(power: PowerSource, network: NetworkID?, lidClosed: Bool) {
        self.power = power
        self.network = network
        self.lidClosed = lidClosed
    }
}

/// The content of status.json. The agent reads `ownsSleepSwitch` back at launch, so a crash or restart still knows
/// whose switch it is.
public struct AgentStatus: Equatable, Codable, Sendable {
    public var snapshot: Snapshot
    public var ownsSleepSwitch: Bool

    public init(snapshot: Snapshot, ownsSleepSwitch: Bool) {
        self.snapshot = snapshot
        self.ownsSleepSwitch = ownsSleepSwitch
    }
}

public struct Prefs: Codable, Equatable, Sendable {
    public var enabled = true
    public var homes: Set<NetworkID> = []

    public init(enabled: Bool = true, homes: Set<NetworkID> = []) {
        self.enabled = enabled
        self.homes = homes
    }
}

public enum Decision: Equatable, Sendable { case stayAwake, allowSleep(Reason) }
public enum Reason: Equatable, Sendable { case paused, onBattery, offline, notHome }

public func decide(_ s: Snapshot, _ p: Prefs) -> Decision {
    guard p.enabled else { return .allowSleep(.paused) }
    guard s.power == .ac else { return .allowSleep(.onBattery) }
    guard let network = s.network else { return .allowSleep(.offline) }
    return p.homes.contains(network) ? .stayAwake : .allowSleep(.notHome)
}

public func statusLine(_ decision: Decision, lidModeInstalled: Bool) -> String {
    switch decision {
    case .stayAwake where lidModeInstalled: "Awake at home, even with the lid closed."
    case .stayAwake: "Awake at home while the lid is open. Closing the lid still sleeps."
    case .allowSleep(.paused): "Paused. This Mac sleeps normally."
    case .allowSleep(.onBattery): "On battery. This Mac sleeps normally."
    case .allowSleep(.offline): "No network. This Mac sleeps normally."
    case .allowSleep(.notHome): "Not on a home network. This Mac sleeps normally."
    }
}

/// What to do with the global `SleepDisabled` switch. Other tools write the same switch, so HomeAwake turns it off
/// only when it was the one that turned it on.
public struct SleepSwitchPlan: Equatable, Sendable {
    /// The value to write, or nil to leave the switch alone.
    public var write: Bool?
    /// Whether HomeAwake owns the switch once the write succeeds. A failed write leaves ownership as it was.
    public var owned: Bool
    /// Put the Mac to sleep after the write, so a Mac unplugged with the lid shut does not stay awake in a bag.
    public var sleepNow: Bool

    public init(write: Bool?, owned: Bool, sleepNow: Bool = false) {
        self.write = write
        self.owned = owned
        self.sleepNow = sleepNow
    }
}

/// `canWrite` costs a sudo spawn, so it is evaluated only when the plan would write.
public func planSleepSwitch(stayAwake: Bool, sleepDisabled: Bool, owned: Bool, canWrite: @autoclosure () -> Bool,
                            lidClosed: Bool, terminating: Bool) -> SleepSwitchPlan {
    let leave = SleepSwitchPlan(write: nil, owned: owned)
    switch (stayAwake, sleepDisabled, owned) {
    case (true, true, _):
        return leave
    case (true, false, _):
        return canWrite() ? SleepSwitchPlan(write: true, owned: true) : leave
    case (false, true, true):
        return canWrite() ? SleepSwitchPlan(write: false, owned: false, sleepNow: lidClosed && !terminating) : leave
    case (false, false, _), (false, true, false):
        return SleepSwitchPlan(write: nil, owned: false)
    }
}
