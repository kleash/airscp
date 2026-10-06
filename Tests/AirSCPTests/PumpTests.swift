import Darwin
import Foundation
import Testing
@testable import AirSCPCore

/// A sh command line for the pump tests.
private func sh(_ script: String, _ arguments: String...) -> [String] {
    ["/bin/sh", "-c", script, "sh"] + arguments
}

@Test func pumpDropsNoiseBeforeTheMarkerAndCountsBytes() async throws {
    let dir = try scratch()
    try writeRandom(bytes: 1_000_000, to: dir + "/source")
    let sink = open(dir + "/copy", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
    let counts = Recorder<Int64>()
    let pumped = await Runner.pump(sh("echo login noise; echo more >&2; printf '\\n__AIRSCP__\\n'; cat \"$1\"", dir + "/source"),
                                   hostID: nil, log: nil, into: .file(sink), after: TransferQueue.marker,
                                   cancellation: Cancellation()) { counts.append($0) }
    #expect(pumped.started && pumped.bytes == 1_000_000 && pumped.producer.status == 0 && pumped.writeError == nil)
    #expect(pumped.producer.stderr == "more\n")
    #expect(FileManager.default.contentsEqual(atPath: dir + "/source", andPath: dir + "/copy"))
    #expect(counts.all.last == 1_000_000 && counts.all == counts.all.sorted())

    // No marker: nothing is written, and the stream counts as not started.
    let other = open(dir + "/none", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
    let none = await Runner.pump(sh("echo 'This service allows sftp connections only.'"), hostID: nil, log: nil,
                                 into: .file(other), after: TransferQueue.marker, cancellation: Cancellation()) { _ in }
    let written = try FileManager.default.attributesOfItem(atPath: dir + "/none")[.size] as? Int
    #expect(!none.started && none.bytes == 0 && written == 0)
    // Endless noise without a marker is given up after a megabyte (the producer is stopped).
    let endless = open(dir + "/endless", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
    let noise = await Runner.pump(["/usr/bin/yes"], hostID: nil, log: nil, into: .file(endless), after: TransferQueue.marker,
                                  cancellation: Cancellation()) { _ in }
    #expect(!noise.started && noise.producer.status != 0)
}

@Test func pumpIntoACommand() async throws {
    let dir = try scratch()
    try writeRandom(bytes: 3_000_000, to: dir + "/source")
    let logged = Recorder<LogEntry>()
    let pumped = await Runner.pump(["/bin/cat", dir + "/source"], hostID: nil, log: nil,
                                   into: .command(sh("cat > \"$1\"", dir + "/copy"), environment: [:], hostID: nil,
                                                  log: { logged.append($0) }),
                                   after: nil, cancellation: Cancellation()) { _ in }
    #expect(pumped.consumer?.status == 0 && pumped.producer.status == 0 && pumped.bytes == 3_000_000)
    #expect(FileManager.default.contentsEqual(atPath: dir + "/source", andPath: dir + "/copy"))
    // Logged on the main queue before the pump returned: its turn comes before this one's (the app tests keep the
    // queue busy for a minute and more on a busy Mac).
    await MainActor.run {}
    #expect(logged.all.contains { $0.command.hasPrefix("/bin/sh -c 'cat > ") })
}

@Test func aConsumerThatEndsEarlyStopsTheProducer() async throws {
    let start = Date()
    let pumped = await Runner.pump(["/usr/bin/yes"], hostID: nil, log: nil,
                                   into: .command(sh("head -c 100000 >/dev/null; echo refused >&2; exit 3"), environment: [:],
                                                  hostID: nil, log: nil),
                                   after: nil, cancellation: Cancellation()) { _ in }
    #expect(Date().timeIntervalSince(start) < 30)  // stopped: yes runs for ever
    #expect(pumped.consumer?.status == 3 && pumped.consumer?.stderr == "refused\n")
    #expect(pumped.writeError == EPIPE && pumped.producer.status != 0)
}

@Test func cancellingAPumpStopsBothCommands() async throws {
    let cancellation = Cancellation()
    let counts = Recorder<Int64>()
    let task = Task {
        await Runner.pump(["/usr/bin/yes"], hostID: nil, log: nil,
                          into: .command(["/bin/cat"], environment: [:], hostID: nil, log: nil),
                          after: nil, cancellation: cancellation) { counts.append($0) }
    }
    #expect(await eventually { !counts.all.isEmpty })
    let start = Date()
    cancellation.cancel()
    let pumped = await task.value
    #expect(Date().timeIntervalSince(start) < 30)  // stopped, not waited for (5 s were too few on a busy Mac)
    #expect(pumped.producer.status == 128 + SIGTERM && pumped.consumer?.status == 128 + SIGTERM)
}
