import Foundation
import IOKit

public let reconcileRequested = "dev.homeawake.reconcile"

public enum Files {
    static let support = URL.applicationSupportDirectory.appending(path: "HomeAwake")
    public static let prefs = support.appending(path: "prefs.json")
    public static let status = support.appending(path: "status.json")
    public static let launchAgent = URL.libraryDirectory.appending(path: "LaunchAgents/\(agentLabel).plist")
}

public func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

public func writeIfChanged(_ data: Data, to url: URL) throws -> Bool {
    guard (try? Data(contentsOf: url)) != data else { return false }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    return true
}

public func save(_ value: some Encodable, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    _ = try writeIfChanged(encoder.encode(value), to: url)
}

private let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))

public func rootDomainFlag(_ key: String) -> Bool {
    IORegistryEntryCreateCFProperty(rootDomain, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
        ?? false
}

public func sudoGrantsLidMode() -> Bool {
    grantsLidMode(sudoList: run(["/usr/bin/sudo", "-n", "-l"]).output)
}

/// Plans against the switch as it is now and runs the write with `sudo -n`. Returns the new ownership, and whether this
/// call just turned off the switch HomeAwake owned.
public func updateSleepSwitch(stayAwake: Bool, owned: Bool) -> (owned: Bool, released: Bool) {
    let plan = planSleepSwitch(stayAwake: stayAwake, sleepDisabled: rootDomainFlag("SleepDisabled"), owned: owned,
                               canWrite: sudoGrantsLidMode())
    guard let value = plan.write else { return (plan.owned, false) }
    let command = ["/usr/bin/sudo", "-n"] + Pmset.disablesleep(value)
    guard run(command).ok else {
        NSLog("%@ failed", command.joined(separator: " "))
        return (owned, false)
    }
    return (plan.owned, !value)
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
    guard spawned == 0 else {
        NSLog("posix_spawn %@ failed: errno %d, %s", argv[0], spawned, strerror(spawned))
        return (false, "")
    }

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
