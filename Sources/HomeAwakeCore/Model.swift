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

/// What the agent last observed. It is also the content of status.json.
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
