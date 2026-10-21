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
    case start, useAsHome(NetworkID), forgetHome(NetworkID), pause, resume, setUpLidMode, hideIcon, quit
}

/// The top of the menu, written for someone who wants to know whether their phone can reach the Mac right now.
public struct Headline: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var awake: Bool

    public init(_ title: String, _ detail: String, awake: Bool = false) {
        self.title = title
        self.detail = detail
        self.awake = awake
    }
}

public enum MenuRow: Equatable, Sendable {
    case headline(Headline), toggle(String, isOn: Bool, MenuAction), action(String, MenuAction), separator
}

func headline(_ s: MenuState) -> Headline {
    switch (s.agentRunning, s.decision) {
    case (false, _): Headline("HomeAwake is not running", "Start it again to keep your Mac awake at home.")
    case (true, nil): Headline("HomeAwake is starting", "It's checking your network and power.")
    case (true, .stayAwake?) where s.sleepDisabled:
        Headline("Your Mac is staying awake",
                 "You're home and plugged in, so your phone can reach it, even with the lid closed.", awake: true)
    case (true, .stayAwake?):
        Headline("Your Mac is staying awake",
                 "You're home and plugged in. Closing the lid will still put it to sleep.", awake: true)
    case (true, .allowSleep(.paused)?): Headline("HomeAwake is off", "Your Mac sleeps as usual.")
    case (true, .allowSleep(.onBattery)?):
        Headline("Your Mac sleeps as usual", "It's on battery. HomeAwake works only while it's plugged in.")
    case (true, .allowSleep(.notHome)?): Headline("Your Mac sleeps as usual", "This isn't your home network.")
    case (true, .hold?): Headline("Waiting for a network", "Your Mac stays as it is until the network is back.")
    }
}

public func menuRows(_ s: MenuState) -> [MenuRow] {
    var rows: [MenuRow] = [.headline(headline(s)), .separator]
    if !s.agentRunning { rows.append(.action("Start HomeAwake", .start)) }
    rows.append(.toggle("Keep Awake at Home", isOn: s.enabled, s.enabled ? .pause : .resume))
    if let network = s.network {
        rows.append(.toggle("This Is My Home Network", isOn: s.isHome,
                            s.isHome ? .forgetHome(network) : .useAsHome(network)))
    }
    if !s.lidModeAvailable { rows.append(.action("Stay Awake with the Lid Closed…", .setUpLidMode)) }
    return rows + [.separator, .action("Hide Menu Bar Icon", .hideIcon), .action("Quit HomeAwake", .quit)]
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
