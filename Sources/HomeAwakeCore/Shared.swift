import Foundation

public let prefsChanged = "dev.homeawake.prefs"

public enum Files {
    static let home = URL(fileURLWithPath: getenv("HOME").map { String(cString: $0) } ?? NSHomeDirectory())
    public static let prefs = home.appending(path: "Library/Application Support/HomeAwake/prefs.json")
    public static let status = home.appending(path: "Library/Application Support/HomeAwake/status.json")
    public static let launchAgent = home.appending(path: "Library/LaunchAgents/\(agentLabel).plist")
}

public func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

/// Leaves the file untouched when its content would not change.
public func save(_ value: some Encodable, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    guard (try? Data(contentsOf: url)) != data else { return }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

public func lidModeAvailable() -> Bool {
    grantsLidMode(sudoList: run(["/usr/bin/sudo", "-n", "-l"]).output)
}

/// Runs a program to completion. `ok` means it exited with status 0.
/// Plain posix_spawn: Foundation's Process leaves a helper thread and about 270 KB resident in the agent.
@discardableResult
public func run(_ argv: [String]) -> (ok: Bool, output: String) {
    var ends: [Int32] = [0, 0]
    guard pipe(&ends) == 0 else { return (false, "") }
    let (readEnd, writeEnd) = (ends[0], ends[1])
    defer { close(readEnd) }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addclose(&actions, readEnd)
    posix_spawn_file_actions_addclose(&actions, writeEnd)

    let cArgs = argv.map { strdup($0) } + [nil]
    defer { cArgs.forEach { free($0) } }
    var pid = pid_t(0)
    let spawned = posix_spawn(&pid, argv[0], &actions, nil, cArgs, environ)
    close(writeEnd)
    guard spawned == 0 else { return (false, "") }

    var output: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(readEnd, &chunk, chunk.count)
        guard count > 0 else { break }
        output += chunk[..<count]
    }
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    return (status == 0, String(decoding: output, as: UTF8.self))
}
