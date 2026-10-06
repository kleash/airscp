import Darwin
import Foundation
import Testing
@testable import AirSCPCore

/// PLAN.md S: a 50 000-entry folder must list fast; the parser reads bytes, no regular expression. (The budget is for
/// a debug build; a release build parses this in well under 0.1 s.)
@Test func listingParserHandles50000Entries() {
    var lines = ["sftp> cd \"/srv\"", "sftp> ls -lan",
                 "drwxr-xr-x    ? 1000     1000         4096 Oct  2 11:39 .",
                 "drwxr-xr-x    ? 0        0            4096 Jan  1  2024 .."]
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    for index in 0..<50_000 {
        let day = String(format: "%2d", index % 28 + 1)
        let time = index % 3 == 0 ? " \(2000 + index % 25)" : String(format: "%02d:%02d", index % 24, index % 60)
        lines.append("-rw-r--r--    ? 1000     1000     \(index * 37) \(months[index % 12]) \(day) \(time) file-\(index).txt")
    }
    let output = lines.joined(separator: "\n") + "\n"
    // This thread's CPU time: other tests running at the same time don't count.
    func cpuTime() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
    }
    let start = cpuTime()
    let entries = Listing.parse(output, in: "/srv")
    let elapsed = cpuTime() - start
    print("PERF parsing a 50000-line listing: \(String(format: "%.3f", elapsed)) s of CPU")
    #expect(entries.count == 50_000)
    #expect(entries[49_999].name == "file-49999.txt" && entries[49_999].size == 49_999 * 37)
    #expect(elapsed < 3, "parsing took \(elapsed) s")
}

/// GNU ls as `Session.list` runs it on a shell host (C locale, dates in UTC, link targets after " -> ").
@Test func shellListingWithLinkTargets() throws {
    let now = Listing.utc.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12))!
    let output = """
        total 3026944
        drwx------ 2 0 0    4096 Oct  2 15:54 .
        drwxrwxrwt 1 0 0    4096 Oct  2 15:54 ..
        -rw-r--r-- 1 0 0 3000000 Oct  2 11:54 big
        lrwxrwxrwx 1 0 0      14 Oct  2 11:54 link to dir -> dir with space
        lrwxrwxrwx 1 0 0       6 Jan  2  2020 a -> b -> c
        -rw-r--r-- 1 0 0       1 Oct  2 11:54 not -> a link
        -rw-r--r-- 1 1000 1000 0 Jan  2  2020 old

        """
    var lines = output.components(separatedBy: "\n")
    lines.remove(at: 5)  // the ambiguous link
    let entries = try #require(Listing.parse(lines.joined(separator: "\n"), in: "/d", now: now, calendar: Listing.utc,
                                             linkTargets: true))
    #expect(entries.map(\.name) == ["big", "link to dir", "not -> a link", "old"])
    #expect(entries[0].size == 3_000_000 && entries[1].kind == .symlink && entries[1].path == "/d/link to dir")
    let components = Listing.utc.dateComponents([.year, .month, .day, .hour, .minute], from: entries[0].modified!)
    #expect(components == DateComponents(year: 2026, month: 10, day: 2, hour: 11, minute: 54))
    #expect(Listing.utc.component(.year, from: entries[3].modified!) == 2020)
    // A link whose name or target holds " -> " can't be split: the caller lists with sftp instead.
    #expect(Listing.parse(output, in: "/d", now: now, calendar: Listing.utc, linkTargets: true) == nil)
    // sftp's own ls shows no targets: there the name is the whole rest of the line.
    #expect(Listing.parse(output, in: "/d", now: now).map(\.name).contains("a -> b -> c"))
}

/// A hostile server's listing can name entries "../x" or "a/b": downloads join the name to a folder on this Mac, so
/// such entries must never come out of the parser (from a shell's ls or from sftp's).
@Test func namesWithASlashAreLeftOut() throws {
    let now = Listing.utc.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12))!
    let output = """
        -rw-r--r-- 1 501 20 6 Oct  2 11:39 before
        -rw-r--r-- 1 501 20 6 Oct  2 11:39 ../planted.txt
        -rw-r--r-- 1 501 20 6 Oct  2 11:39 ../../.ssh/authorized_keys
        drwxr-xr-x 2 501 20 64 Oct  2 11:39 a/b
        -rw-r--r-- 1 501 20 6 Oct  2 11:39 /etc/passwd
        lrwxr-xr-x 1 501 20 6 Oct  2 11:39 up/../x -> /tmp
        lrwxr-xr-x 1 501 20 6 Oct  2 11:39 link -> ../../outside
        -rw-r--r-- 1 501 20 6 Oct  2 11:39 after

        """
    let shell = try #require(Listing.parse(output, in: "/d", now: now, calendar: Listing.utc, linkTargets: true))
    #expect(shell.map(\.name) == ["before", "link", "after"])  // a link's target may go anywhere: it stays a link
    // sftp's ls prints no targets: there all of the rest is the name, and one with a "/" can't be a file's.
    #expect(Listing.parse(output, in: "/d", now: now).map(\.name) == ["before", "after"])
}
