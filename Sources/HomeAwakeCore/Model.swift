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

    public init(power: PowerSource, network: NetworkID?) {
        self.power = power
        self.network = network
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
    public var enabled: Bool
    public var homes: Set<NetworkID>

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

/// What to do with the global `SleepDisabled` switch. Other tools write the same switch, so HomeAwake turns it off
/// only when it was the one that turned it on.
public struct SleepSwitchPlan: Equatable, Sendable {
    /// The value to write, or nil to leave the switch alone.
    public var write: Bool?
    /// Whether HomeAwake owns the switch once the write succeeds. A failed write leaves ownership as it was.
    public var owned: Bool

    public init(write: Bool?, owned: Bool) {
        self.write = write
        self.owned = owned
    }
}

/// `canWrite` guards only turning the switch on, so HomeAwake never turns on a switch it could not turn off. Turning
/// its own switch off just tries the write, and a failed `sudo -n` keeps ownership.
public func planSleepSwitch(stayAwake: Bool, sleepDisabled: Bool, owned: Bool, canWrite: @autoclosure () -> Bool)
    -> SleepSwitchPlan {
    switch (stayAwake, sleepDisabled, owned) {
    case (true, true, _):
        return SleepSwitchPlan(write: nil, owned: owned)
    case (true, false, _):
        return canWrite() ? SleepSwitchPlan(write: true, owned: true) : SleepSwitchPlan(write: nil, owned: owned)
    case (false, true, true):
        return SleepSwitchPlan(write: false, owned: false)
    case (false, false, _), (false, true, false):
        return SleepSwitchPlan(write: nil, owned: false)
    }
}
