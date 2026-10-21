/// What the menu bar icon and its menu show.
public struct MenuState: Equatable, Sendable {
    /// Nil while the agent has written no status yet.
    public var decision: Decision?
    public var agentRunning: Bool
    public var sleepDisabled: Bool
    public var network: NetworkID?
    public var isHome: Bool
    public var enabled: Bool
    public var lidModeAvailable: Bool

    public init(decision: Decision?, agentRunning: Bool, sleepDisabled: Bool, network: NetworkID?, isHome: Bool,
                enabled: Bool, lidModeAvailable: Bool) {
        self.decision = decision
        self.agentRunning = agentRunning
        self.sleepDisabled = sleepDisabled
        self.network = network
        self.isHome = isHome
        self.enabled = enabled
        self.lidModeAvailable = lidModeAvailable
    }
}

public enum MenuAction: Equatable, Sendable {
    case useAsHome(NetworkID), forgetHome(NetworkID), pause, resume, setUpLidMode, hideIcon, remove
}

public enum MenuRow: Equatable, Sendable { case info(String), action(String, MenuAction), separator }

public func menuRows(_ s: MenuState) -> [MenuRow] {
    let status = switch (s.agentRunning, s.decision) {
    case (false, _): "The HomeAwake agent is not running."
    case (true, nil): "HomeAwake is starting."
    case let (true, decision?): statusLine(decision, sleepDisabled: s.sleepDisabled)
    }
    var rows: [MenuRow] = [.info(status), .info(infoLine(network: s.network, lidModeAvailable: s.lidModeAvailable)),
                           .separator]
    if let network = s.network {
        rows.append(s.isHome ? .action("Forget this home network", .forgetHome(network))
                             : .action("Use this network as home", .useAsHome(network)))
    }
    rows.append(s.enabled ? .action("Pause", .pause) : .action("Resume", .resume))
    if !s.lidModeAvailable { rows.append(.action("Set up lid-closed mode…", .setUpLidMode)) }
    return rows + [.separator, .action("Hide menu bar icon", .hideIcon), .action("Remove HomeAwake", .remove)]
}

/// An SF Symbol name.
public func iconSymbol(_ s: MenuState) -> String {
    switch (s.agentRunning, s.decision) {
    case (true, .stayAwake?) where s.sleepDisabled: "sun.max.fill"
    case (true, .stayAwake?): "sun.max"
    case (true, .hold?): "wifi.slash"
    default: "moon.zzz"
    }
}
