public enum PowerSource: String, Codable, Sendable { case ac, battery }

/// A network, identified by its default gateway's MAC address. Every value is normalized: lowercase, two hex digits
/// per octet. It encodes as a bare string.
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

/// Only a positive signal allows sleep. Without a network, `hold` keeps the Mac as it was, so a router restart or a
/// Wi-Fi reconnect at home does not put it to sleep.
public enum Decision: Equatable, Sendable { case stayAwake, allowSleep(Reason), hold }
public enum Reason: Equatable, Sendable { case paused, onBattery, notHome }

public func decide(_ s: Snapshot, _ p: Prefs) -> Decision {
    guard p.enabled else { return .allowSleep(.paused) }
    guard s.power == .ac else { return .allowSleep(.onBattery) }
    guard let network = s.network else { return .hold }
    return p.homes.contains(network) ? .stayAwake : .allowSleep(.notHome)
}

public func statusLine(_ decision: Decision, lidModeAvailable: Bool) -> String {
    switch decision {
    case .stayAwake where lidModeAvailable: "Awake at home, even with the lid closed."
    case .stayAwake: "Awake at home while the lid is open. Closing the lid still sleeps."
    case .allowSleep(.paused): "Paused. This Mac sleeps normally."
    case .allowSleep(.onBattery): "On battery. This Mac sleeps normally."
    case .allowSleep(.notHome): "Not on a home network. This Mac sleeps normally."
    case .hold: "No network right now. HomeAwake keeps the Mac as it was until the network is back."
    }
}

public func infoLine(network: NetworkID?, lidModeAvailable: Bool) -> String {
    let router = network.map { "This network's router is \($0.gatewayMAC)." } ?? "No router found on this network."
    return router + (lidModeAvailable ? " Lid-closed mode is available." : " Lid-closed mode is not set up.")
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

public func planSleepSwitch(stayAwake: Bool, sleepDisabled: Bool, owned: Bool, canWrite: @autoclosure () -> Bool,
                            sleepAfterRelease: Bool) -> SleepSwitchPlan {
    let leave = SleepSwitchPlan(write: nil, owned: owned)
    switch (stayAwake, sleepDisabled, owned) {
    case (true, true, _):
        return leave
    case (true, false, _):
        return canWrite() ? SleepSwitchPlan(write: true, owned: true) : leave
    case (false, true, true):
        return canWrite() ? SleepSwitchPlan(write: false, owned: false, sleepNow: sleepAfterRelease) : leave
    case (false, false, _), (false, true, false):
        return SleepSwitchPlan(write: nil, owned: false)
    }
}
