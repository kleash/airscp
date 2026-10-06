import Darwin
import Foundation
import Testing
@testable import AirSCPCore

// The fixtures are what `Monitor.script` printed in throwaway containers (Docker Desktop's Linux VM, 6 CPUs) with a few
// awkward processes running: a command name with a space ("my sleeper"), a user name longer than ps's column, a zombie,
// a busy loop, a 100 MB process, a niced one and a non-ASCII argument (GNU ps prints its bytes as "?" in the C locale).

/// debian:stable-slim + procps (procps-ng 4.0.4, dash), first refresh: GNU ps answers.
private let debianOutput = #"""
Linux 7.0.12-linuxkit
@@stat
cpu  1434031 0 375116 84873763 730566 0 373860 0 0 0
@@loadavg
2.00 1.55 0.88 3/442 238
@@uptime
146622.25 848737.63
@@meminfo
MemTotal:        8125028 kB
MemFree:          291468 kB
MemAvailable:    1475920 kB
Buffers:           45900 kB
Cached:          1126364 kB
SwapCached:        93132 kB
Active:          3692952 kB
Inactive:        3712228 kB
Active(anon):    3613872 kB
Inactive(anon):  2619532 kB
Active(file):      79080 kB
Inactive(file):  1092696 kB
Unevictable:           0 kB
Mlocked:               0 kB
SwapTotal:       1048572 kB
SwapFree:         384912 kB
Zswap:                 0 kB
Zswapped:              0 kB
Dirty:                 8 kB
Writeback:             0 kB
AnonPages:       6146824 kB
Mapped:           185508 kB
Shmem:               508 kB
KReclaimable:     216048 kB
Slab:             283840 kB
SReclaimable:     216048 kB
SUnreclaim:        67792 kB
KernelStack:        7136 kB
PageTables:        19848 kB
SecPageTables:         0 kB
NFS_Unstable:          0 kB
Bounce:                0 kB
WritebackTmp:          0 kB
CommitLimit:     5111084 kB
Committed_AS:    9640052 kB
VmallocTotal:   135288315904 kB
VmallocUsed:       14472 kB
VmallocChunk:          0 kB
Percpu:             2760 kB
AnonHugePages:   2531328 kB
ShmemHugePages:        0 kB
ShmemPmdMapped:        0 kB
FileHugePages:    538624 kB
FilePmdMapped:         0 kB
Balloon:               0 kB
HugePages_Total:       0
HugePages_Free:        0
HugePages_Rsvd:        0
HugePages_Surp:        0
Hugepagesize:       2048 kB
Hugetlb:               0 kB
@@os
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
VERSION_ID="13"
VERSION="13 (trixie)"
VERSION_CODENAME=trixie
DEBIAN_VERSION_FULL=13.7
ID=debian
HOME_URL="https://www.debian.org/"
SUPPORT_URL="https://www.debian.org/support"
BUG_REPORT_URL="https://bugs.debian.org/"
@@ps
    PID    PPID USER     %CPU %MEM   RSS     ELAPSED STAT COMMAND         COMMAND
      1       0 root      0.0  0.0  1228       08:04 Ss   sleep           sleep infinity
     64       1 root      0.0  0.0     0       07:37 Z    dpkg-preconfigu [dpkg-preconfigu] <defunct>
    162       1 root      0.0  0.0  1276       07:30 S    sleep           sleep 1000 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80 81 82 83 84 85 86 87 88 89 90 91 92 93 94 95 96 97 98 99 100 101 102 103 104 105 106 107 108 109 110 111 112 113 114 115 116 117 118 119 120 121 122 123 124 125 126 127 128 129 130 131 132 133 134 135 136 137 138 139 140 141 142 143 144 145 146 147 148 149 150 151 152 153 154 155 156 157 158 159 160 161 162 163 164 165 166 167 168 169 170 171 172 173 174 175 176 177 178 179 180 181 182 183 184 185 186 187 188 189 190 191 192 193 194 195 196 197 198 199 200
    190       0 root      0.0  0.0  1504       06:41 Ss   sh              sh -c "/tmp/my sleeper" 1000 & setpriv --reuid=1234 --regid=1234 --clear-groups sleep 1001 & sh -c "sleep 0.1 & exec sleep 1002" & tail -f "/tmp/caf??" & sh -c "while :; do :; done" & dd if=/dev/zero bs=100M count=1 2>/dev/null | sleep 1003 & nice -n 10 sleep 1004 & wait
    197     190 root      0.0  0.0  1292       06:41 S    my sleeper      /tmp/my sleeper 1000
    198     190 averyve+  0.0  0.0  1288       06:41 S    sleep           sleep 1001
    199     190 root      0.0  0.0  1288       06:41 S    sleep           sleep 1002
    200     190 root      0.0  0.0  1324       06:41 S    tail            tail -f /tmp/caf??
    201     199 root      0.0  0.0     0       06:41 Z    sleep           [sleep] <defunct>
    202     190 root     99.9  0.0  1440       06:41 R    sh              sh -c while :; do :; done
    203     190 root      0.0  1.2 103724      06:41 S    dd              dd if=/dev/zero bs=100M count=1
    204     190 root      0.0  0.0  1288       06:41 S    sleep           sleep 1003
    205     190 root      0.0  0.0  1288       06:41 SN   sleep           sleep 1004
    229       0 root      0.0  0.0  1540       00:00 Ss   sh              sh -c LC_ALL=C; export LC_ALL; s=$(uname -sr); echo "$s"; case $s in Linux*) echo @@stat; head -n 1 /proc/stat; echo @@loadavg; cat /proc/loadavg; echo @@uptime; cat /proc/uptime; echo @@meminfo; cat /proc/meminfo; echo @@os; cat /etc/os-release; echo @@ps; ps -ww -eo pid,ppid,user,pcpu,pmem,rss,etime,stat,comm,args 2>&1 || ps -o pid,ppid,user,rss,etime,stat,comm,args 2>&1; echo @@df; df -kP;; esac 2>/dev/null; true
    242     229 root      0.0  0.0  3240       00:00 R    ps              ps -ww -eo pid,ppid,user,pcpu,pmem,rss,etime,stat,comm,args
@@df
Filesystem     1024-blocks      Used Available Capacity Mounted on
overlay          288666560 140870492 133099680      52% /
tmpfs                65536         0     65536       0% /dev
shm                  65536         0     65536       0% /dev/shm
/dev/vda1        288666560 140870492 133099680      52% /etc/hosts
tmpfs                    4         0         4       0% /proc/scsi
"""#

/// The same server's /proc/stat CPU line 2 seconds later.
private let debianNextCPULine = "cpu  1434449 0 375118 84874583 730566 0 373864 0 0 0"

/// alpine:latest (BusyBox 1.37.0), first refresh: GNU ps's options are refused (with BusyBox's usage text), then
/// BusyBox ps answers.
private let alpineOutput = #"""
Linux 7.0.12-linuxkit
@@stat
cpu  1434462 0 375120 84874598 730566 0 373865 0 0 0
@@loadavg
2.16 1.59 0.90 3/442 106
@@uptime
146624.37 848745.99
@@meminfo
MemTotal:        8125028 kB
MemFree:          290452 kB
MemAvailable:    1474904 kB
Buffers:           45900 kB
Cached:          1126364 kB
SwapCached:        93132 kB
Active:          3693096 kB
Inactive:        3712228 kB
Active(anon):    3614016 kB
Inactive(anon):  2619532 kB
Active(file):      79080 kB
Inactive(file):  1092696 kB
Unevictable:           0 kB
Mlocked:               0 kB
SwapTotal:       1048572 kB
SwapFree:         384912 kB
Zswap:                 0 kB
Zswapped:              0 kB
Dirty:                 8 kB
Writeback:             0 kB
AnonPages:       6147008 kB
Mapped:           185528 kB
Shmem:               508 kB
KReclaimable:     216048 kB
Slab:             283840 kB
SReclaimable:     216048 kB
SUnreclaim:        67792 kB
KernelStack:        7164 kB
PageTables:        19764 kB
SecPageTables:         0 kB
NFS_Unstable:          0 kB
Bounce:                0 kB
WritebackTmp:          0 kB
CommitLimit:     5111084 kB
Committed_AS:    9627360 kB
VmallocTotal:   135288315904 kB
VmallocUsed:       14360 kB
VmallocChunk:          0 kB
Percpu:             2760 kB
AnonHugePages:   2531328 kB
ShmemHugePages:        0 kB
ShmemPmdMapped:        0 kB
FileHugePages:    538624 kB
FilePmdMapped:         0 kB
Balloon:               0 kB
HugePages_Total:       0
HugePages_Free:        0
HugePages_Rsvd:        0
HugePages_Surp:        0
Hugepagesize:       2048 kB
Hugetlb:               0 kB
@@os
NAME="Alpine Linux"
ID=alpine
VERSION_ID=3.24.1
PRETTY_NAME="Alpine Linux v3.24"
HOME_URL="https://alpinelinux.org/"
BUG_REPORT_URL="https://gitlab.alpinelinux.org/alpine/aports/-/issues"
@@ps
ps: unrecognized option: w
BusyBox v1.37.0 (2026-01-10 15:38:28 UTC) multi-call binary.

Usage: ps [-o COL1,COL2=HEADER] [-T]

Show list of processes

	-o COL1,COL2=HEADER	Select columns for display
	-T			Show threads
PID   PPID  USER     RSS  ELAPSED STAT COMMAND          COMMAND
    1     0 root      720  8:07   S    sleep            sleep infinity
   42     0 root      848  2:07   S    sh               sh -c "/tmp/my sleeper" sleep 1000 & setpriv --reuid=1234 --regid=1234 --clear-groups sleep 1001 & sh -c "sleep 0.1 & exec sleep 1002" & tail -f "/tmp/café" & sh -c "while :; do :; done" & dd if=/dev/zero bs=100M count=1 2>/dev/null | sleep 1003 & nice -n 10 sleep 1004 & wait
   50    42 root      848  2:07   S    sleep            sleep 1002
   51    42 root      848  2:07   S    tail             tail -f /tmp/café
   52    42 root      844  2:07   R    sh               sh -c while :; do :; done
   53    50 root        0  2:07   Z    sleep            [sleep]
   54    42 root     100m  2:07   S    dd               dd if /dev/zero bs 100M count 1
   55    42 root      848  2:07   S    sleep            sleep 1003
   56    42 root      720  2:07   SN   sleep            sleep 1004
   83     0 root      844  0:41   S    sh               sh -c "/tmp/my sleeper" & su -s /bin/sh averyveryverylongusername -c "sleep 1001" & wait
   89    83 root      848  0:41   S    my sleeper       {my sleeper} /bin/sh /tmp/my sleeper
   90    83 averyver  844  0:41   S    sleep            sleep 1001
   91    89 root      844  0:41   S    sleep            sleep 1000
   98     0 root      976  0:01   S    sh               sh -c LC_ALL=C; export LC_ALL; s=$(uname -sr); echo "$s"; case $s in Linux*) echo @@stat; head -n 1 /proc/stat; echo @@loadavg; cat /proc/loadavg; echo @@uptime; cat /proc/uptime; echo @@meminfo; cat /proc/meminfo; echo @@os; cat /etc/os-release; echo @@ps; ps -ww -eo pid,ppid,user,pcpu,pmem,rss,etime,stat,comm,args 2>&1 || ps -o pid,ppid,user,rss,etime,stat,comm,args 2>&1; echo @@df; df -kP;; esac 2>/dev/null; true
  111    98 root      976  0:01   R    ps               ps -o pid,ppid,user,rss,etime,stat,comm,args
@@df
Filesystem           1024-blocks    Used Available Capacity Mounted on
overlay              288666560 140870492 133099680  51% /
tmpfs                    65536         0     65536   0% /dev
shm                      65536         0     65536   0% /dev/shm
/dev/vda1            288666560 140870492 133099680  51% /etc/hostname
/dev/vda1            288666560 140870492 133099680  51% /etc/hosts
/dev/vda1            288666560 140870492 133099680  51% /etc/resolv.conf
tmpfs                    65536         0     65536   0% /proc/interrupts
tmpfs                    65536         0     65536   0% /proc/kcore
tmpfs                    65536         0     65536   0% /proc/keys
tmpfs                        4         0         4   0% /proc/scsi
tmpfs                    65536         0     65536   0% /proc/timer_list
tmpfs                        4         0         4   0% /sys/firmware
"""#

private func process(_ pid: Int, in snapshot: MonitorSnapshot) -> MonitorProcess? {
    snapshot.processes.first { $0.pid == pid }
}

@Test func monitorReadsADebianServer() throws {
    let reading = Monitor.parse(debianOutput)
    #expect(reading.linux && reading.uname == "Linux 7.0.12-linuxkit")
    #expect(reading.cpu == Monitor.CPUTimes(total: 1434031 + 375116 + 84873763 + 730566 + 373860,
                                            idle: 84873763 + 730566))
    #expect(reading.ps == .gnu)
    let snapshot = reading.snapshot
    #expect(snapshot.cpu == nil)
    #expect(snapshot.system == "Debian GNU/Linux 13 (trixie)")
    #expect(snapshot.load == [2.00, 1.55, 0.88])
    #expect(snapshot.uptime == 146622.25)
    #expect(snapshot.memoryTotal == 8125028 * 1024 && snapshot.memoryUsed == (8125028 - 1475920) * 1024)
    #expect(snapshot.swapTotal == 1048572 * 1024 && snapshot.swapUsed == (1048572 - 384912) * 1024)
    // tmpfs on /dev, /dev/shm and /proc/scsi are left out; the disk Docker bind-mounts /etc/hosts from stays.
    let (size, used, available): (Int64, Int64, Int64) = (288666560 * 1024, 140870492 * 1024, 133099680 * 1024)
    #expect(snapshot.disks == [
        MonitorDisk(filesystem: "overlay", mountPoint: "/", size: size, used: used, available: available),
        MonitorDisk(filesystem: "/dev/vda1", mountPoint: "/etc/hosts", size: size, used: used, available: available),
    ])

    #expect(snapshot.processNote == nil)
    #expect(snapshot.processes.map(\.pid) == [1, 64, 162, 190, 197, 198, 199, 200, 201, 202, 203, 204, 205, 229, 242])
    #expect(process(1, in: snapshot) == MonitorProcess(pid: 1, ppid: 0, user: "root", cpu: 0, memory: 0,
                                                       rss: 1228 * 1024, elapsed: 8 * 60 + 4, state: "Ss",
                                                       name: "sleep", command: "sleep infinity"))
    #expect(process(197, in: snapshot)?.name == "my sleeper")
    #expect(process(197, in: snapshot)?.command == "/tmp/my sleeper 1000")
    #expect(process(198, in: snapshot)?.user == "averyve+")
    #expect(process(200, in: snapshot)?.command == "tail -f /tmp/caf??")
    let zombie = try #require(process(201, in: snapshot))
    #expect(zombie.state == "Z" && zombie.ppid == 199 && zombie.rss == 0 && zombie.name == "sleep"
            && zombie.command == "[sleep] <defunct>")
    #expect(process(64, in: snapshot)?.name == "dpkg-preconfigu")
    let busy = try #require(process(202, in: snapshot))
    #expect(busy.cpu == 99.9 && busy.state == "R" && busy.command == "sh -c while :; do :; done")
    // RSS wider than its column (GNU ps takes it out of the next column's padding).
    let big = try #require(process(203, in: snapshot))
    #expect(big.rss == 103724 * 1024 && big.memory == 1.2 && big.elapsed == 6 * 60 + 41 && big.name == "dd"
            && big.command == "dd if=/dev/zero bs=100M count=1")
    #expect(process(205, in: snapshot)?.state == "SN")
    #expect(process(162, in: snapshot)?.command.hasSuffix(" 199 200") == true)
    #expect(process(242, in: snapshot)?.command == "ps -ww -eo pid,ppid,user,pcpu,pmem,rss,etime,stat,comm,args")
}

@Test func monitorReadsABusyBoxServer() throws {
    let reading = Monitor.parse(alpineOutput)
    #expect(reading.linux && reading.ps == .busybox)
    let snapshot = reading.snapshot
    #expect(snapshot.system == "Alpine Linux v3.24")
    #expect(snapshot.load == [2.16, 1.59, 0.90] && snapshot.uptime == 146624.37)
    #expect(snapshot.memoryTotal == 8125028 * 1024 && snapshot.memoryUsed == (8125028 - 1474904) * 1024)
    // /etc/hostname, /etc/hosts and /etc/resolv.conf are one file system bind-mounted three times.
    #expect(snapshot.disks.map(\.mountPoint) == ["/", "/etc/hostname"])

    #expect(snapshot.processNote == nil)
    #expect(snapshot.processes.map(\.pid) == [1, 42, 50, 51, 52, 53, 54, 55, 56, 83, 89, 90, 91, 98, 111])
    #expect(snapshot.processes.allSatisfy { $0.cpu == nil })
    #expect(process(1, in: snapshot) == MonitorProcess(pid: 1, ppid: 0, user: "root", cpu: nil,
                                                       memory: 720.0 / 8125028 * 100, rss: 720 * 1024,
                                                       elapsed: 8 * 60 + 7, state: "S", name: "sleep",
                                                       command: "sleep infinity"))
    // BusyBox scales large RSS values: "100m".
    let big = try #require(process(54, in: snapshot))
    #expect(big.rss == 100 * 1024 * 1024 && big.name == "dd")
    #expect(abs((big.memory ?? 0) - 100.0 * 1024 / 8125028 * 100) < 0.0001)
    #expect(process(89, in: snapshot)?.name == "my sleeper")
    #expect(process(89, in: snapshot)?.command == "{my sleeper} /bin/sh /tmp/my sleeper")
    #expect(process(90, in: snapshot)?.user == "averyver")
    #expect(process(51, in: snapshot)?.command == "tail -f /tmp/caf\u{E9}")
    #expect(process(53, in: snapshot)?.state == "Z")
    #expect(process(56, in: snapshot)?.state == "SN")
    #expect(process(111, in: snapshot)?.command == "ps -o pid,ppid,user,rss,etime,stat,comm,args")
}

/// The script's shell prints its pid ($$) first. Its command line says only "sh -s" (the script comes on standard
/// input), so that pid is how the table leaves out AirSCP's own probe: the shell (229, 98) and the ps it ran (242, 111).
@Test func monitorLeavesOutItsOwnProbe() {
    #expect(Monitor.script(.unknown).contains("case $s in Linux*) echo @@sh; echo $$; echo @@stat;"))
    let debian = Monitor.parse(debianOutput.replacingOccurrences(of: "\n@@stat\n", with: "\n@@sh\n229\n@@stat\n"))
    #expect(debian.snapshot.processes.map(\.pid) == [1, 64, 162, 190, 197, 198, 199, 200, 201, 202, 203, 204, 205])
    let alpine = Monitor.parse(alpineOutput.replacingOccurrences(of: "\n@@stat\n", with: "\n@@sh\n98\n@@stat\n"))
    #expect(alpine.snapshot.processes.map(\.pid) == [1, 42, 50, 51, 52, 53, 54, 55, 56, 83, 89, 90, 91])
}

/// A Monitor whose session is never connected (its parsing and bookkeeping need none).
private func idleMonitor() throws -> (Monitor, AskpassServer) {
    let askpass = try AskpassServer(helperPath: "/usr/bin/false")
    return (Monitor(session: Session(host: SSHHost(hostname: "unused.invalid"), jump: nil, askpass: askpass)), askpass)
}

@Test func cpuPercentIsOverTheTimeBetweenTwoRefreshes() throws {
    let (monitor, askpass) = try idleMonitor()
    defer { askpass.close() }
    let first = try monitor.record(Monitor.parse(debianOutput))
    #expect(first.cpu == nil)  // nothing to compare with yet
    #expect(monitor.ps == .gnu)

    let firstLine = try #require(debianOutput.split(separator: "\n").first { $0.hasPrefix("cpu ") })
    let later = debianOutput.replacingOccurrences(of: firstLine, with: debianNextCPULine)
    let next = try monitor.record(Monitor.parse(later))
    // 2 seconds: 1244 ticks of which 820 idle or waiting for I/O.
    let total: Double = (1434449 + 375118 + 84874583 + 730566 + 373864)
        - (1434031 + 375116 + 84873763 + 730566 + 373860)
    let idle: Double = (84874583 + 730566) - (84873763 + 730566)
    #expect(total == 1244 && idle == 820)
    #expect(abs((next.cpu ?? 0) - (total - idle) / total * 100) < 1e-9)
    // The same sample again (no time passed): no figure rather than a division by zero.
    #expect(Monitor.CPUTimes(total: 10, idle: 5).busy(since: Monitor.CPUTimes(total: 10, idle: 5)) == nil)
    #expect(Monitor.CPUTimes(total: 20, idle: 10).busy(since: Monitor.CPUTimes(total: 10, idle: 5)) == 50)
}

@Test func whichPSRunsIsDecidedOnce() throws {
    #expect(Monitor.script(.unknown).contains("echo @@ps; \(Monitor.gnuPS) || \(Monitor.busyboxPS); echo @@df"))
    #expect(Monitor.script(.gnu).contains("echo @@ps; \(Monitor.gnuPS); echo @@df"))
    #expect(Monitor.script(.busybox).contains("echo @@ps; \(Monitor.busyboxPS); echo @@df"))
    #expect(!Monitor.script(.none).contains("@@ps") && !Monitor.script(.none).contains("ps -"))
    // One line, no backslashes or "!" (csh and fish login shells pass it to sh unchanged), ending in success.
    for kind in [Monitor.PSKind.unknown, .gnu, .busybox, .none] {
        let script = Monitor.script(kind)
        #expect(!script.contains("\n") && !script.contains("\\") && !script.contains("!") && script.hasSuffix("; true"))
    }

    let (monitor, askpass) = try idleMonitor()
    defer { askpass.close() }
    // The workspace header's pulse strip reads the figures without ps: that decides nothing about ps.
    let figures = try monitor.record(Monitor.parse("Linux 6.12.48\n@@df\n"), processes: false)
    #expect(figures.processes.isEmpty && monitor.ps == .unknown)
    _ = try monitor.record(Monitor.parse(alpineOutput))
    #expect(monitor.ps == .busybox)
    _ = try monitor.record(Monitor.parse(debianOutput))  // decided: stays BusyBox
    #expect(monitor.ps == .busybox)

    // debian:stable-slim without procps: both attempts say "not found".
    let (other, otherAskpass) = try idleMonitor()
    defer { otherAskpass.close() }
    let notFound = "Linux 6.12.48\n@@ps\nsh: 1: ps: not found\nsh: 1: ps: not found\n@@df\n"
    let noPS = try other.record(Monitor.parse(notFound))
    #expect(noPS.processes.isEmpty && noPS.processNote == Monitor.noPS && other.ps == .none)
    #expect(Monitor.noPS == "The server has no ps command, so processes can't be listed. The figures above still update.")
    // From then on ps isn't run, and the note stays.
    #expect(try other.record(Monitor.parse("Linux 6.12.48\n@@df\n")).processNote == Monitor.noPS)

    // Any other failure is shown and tried again next time.
    let failed = Monitor.parse("Linux 6.12.48\n@@ps\nps: cannot open /proc\n")
    #expect(failed.ps == .unknown)
    #expect(failed.snapshot.processNote == "AirSCP couldn't list the processes: ps: cannot open /proc")
}

@Test func psTimesAndSizes() {
    // GNU etime
    #expect(Monitor.seconds("05:09") == 309)
    #expect(Monitor.seconds("1:02:03") == 3723)
    #expect(Monitor.seconds("12-01:02:03") == TimeInterval(12 * 86400 + 3723))
    // BusyBox etime
    #expect(Monitor.seconds("6:06") == 366)
    #expect(Monitor.seconds("16h05") == TimeInterval(16 * 3600 + 5 * 60))
    #expect(Monitor.seconds("1d16") == TimeInterval(86400 + 16 * 3600))
    #expect(Monitor.seconds("123d") == TimeInterval(123 * 86400))
    for bad in ["", "-", "5", "1:2:3:4", "a:b", "1-2-3:04", "xh05", "1d1d", "-1:00", "9999999999h00", "1:9999999999"] {
        #expect(Monitor.seconds(Substring(bad)) == nil, "\(bad)")
    }
    // KiB: GNU ps's, df's and meminfo's plain numbers, BusyBox ps's four characters.
    #expect(Monitor.byteSize(kilobytes: "103724") == Int64(103724 * 1024))
    #expect(Monitor.byteSize(kilobytes: "9999") == Int64(9999 * 1024))
    #expect(Monitor.byteSize(kilobytes: "12m") == Int64(12 * 1024 * 1024))
    #expect(Monitor.byteSize(kilobytes: "9.2m") == Int64(9.2 * 1024 * 1024))
    #expect(Monitor.byteSize(kilobytes: "1.5g") == Int64(1536 * 1024 * 1024))
    for bad in ["", "-", "m", "nan", "inf", "1e9", "0x10", "-5", "12p", "99999999999999999999"] {
        #expect(Monitor.byteSize(kilobytes: Substring(bad)) == nil, "\(bad)")
    }
}

@Test func otherSystemsAndFiles() throws {
    let (monitor, askpass) = try idleMonitor()
    defer { askpass.close() }
    #expect(throws: AirSCPError.self) { try monitor.record(Monitor.parse("FreeBSD 14.1-RELEASE\n")) }
    do {
        _ = try monitor.record(Monitor.parse(""))
        Issue.record("a server without uname was taken for Linux")
    } catch let error as AirSCPError {
        #expect(error.message == "The system monitor works only on Linux servers. The Files and Tunnels tabs work as usual.")
    }
    #expect(Monitor.prettyName("PRETTY_NAME='Ubuntu 24.04.3 LTS'") == "Ubuntu 24.04.3 LTS")
    #expect(Monitor.prettyName("PRETTY_NAME=Gentoo") == "Gentoo")
    #expect(Monitor.prettyName("PRETTY_NAME=\"\"") == nil && Monitor.prettyName("NAME=\"Debian\"") == nil)
    // No os-release: uname.
    #expect(Monitor.parse("Linux 4.19.0-rpi\n@@os\n@@df\n").snapshot.system == "Linux 4.19.0-rpi")
    // Mount points with spaces, a capacity of "-", empty and pseudo file systems.
    #expect(Monitor.disk("/dev/sdb1  976284 4 926732 1% /media/My Disk") == MonitorDisk(
        filesystem: "/dev/sdb1", mountPoint: "/media/My Disk", size: 976284 * 1024, used: 4 * 1024,
        available: 926732 * 1024))
    #expect(Monitor.disk("none 0 0 0 - /sys/fs/cgroup") == nil)
    #expect(Monitor.disk("/dev/loop0 65024 65024 0 100% /snap/core20/1974") == nil)
    #expect(Monitor.disk("tmpfs 401592 1100 400492 1% /run") == nil)
    #expect(Monitor.disk("tmpfs 4015920 1100 4014820 1% /tmp")?.mountPoint == "/tmp")
    #expect(Monitor.disk("Filesystem     1024-blocks      Used Available Capacity Mounted on") == nil)
    // Linux before 3.14 has no MemAvailable.
    let old = Monitor.parse("Linux 3.2.0\n@@meminfo\nMemTotal: 1000 kB\nMemFree: 100 kB\nBuffers: 50 kB\n"
                            + "Cached: 250 kB\n")
    #expect(old.snapshot.memoryTotal == 1000 * 1024 && old.snapshot.memoryUsed == 600 * 1024)
}

/// A server can print anything: nothing in it may crash AirSCP (overflows, NaN, infinities).
@Test func garbageOutputIsHarmless() {
    let huge = "18446744073709551615"
    let output = """
        Linux 6.1
        @@stat
        cpu  \(Array(repeating: huge, count: 10).joined(separator: " "))
        @@loadavg
        nan inf -1 1/2 3
        @@uptime
        inf 1
        @@meminfo
        MemTotal: 99999999999999999999 kB
        MemFree: 9223372036854775807 kB
        Buffers: 9223372036854775807 kB
        Cached: 9223372036854775807 kB
        SwapTotal: -5 kB
        @@ps
            PID    PPID USER     %CPU %MEM   RSS     ELAPSED STAT COMMAND         COMMAND
        \(huge) \(huge) root nan inf \(huge) 99999999999h05 S x y
              7       1 root     -1.0  inf 1e400 9999999999-00:00:00 S x y
        @@df
        fs \(huge) \(huge) \(huge) 100% /data
        fs 9223372036854775807 1 1 1% /data2
        """
    let reading = Monitor.parse(output)
    let snapshot = reading.snapshot
    #expect(reading.cpu != nil && snapshot.load.isEmpty && snapshot.uptime == 0)
    #expect(snapshot.memoryTotal == 0 && snapshot.memoryUsed == 0 && snapshot.swapTotal == 0)
    #expect(snapshot.disks.isEmpty)
    #expect(snapshot.processes.count == 1)
    let process = snapshot.processes.first
    #expect(process?.pid == 7 && process?.cpu == nil && process?.memory == nil && process?.rss == 0)
    #expect(process?.elapsed == nil)
}

/// GNU ps lets an overlong value push the columns after it to the right, until some padding takes it up (procps's
/// show_one_proc: each column starts where it should, or one space after the previous one). Rows laid out that way.
@Test func processColumnsWithSpacesAndOverflow() {
    let header = "    PID    PPID USER     %CPU %MEM   RSS     ELAPSED STAT COMMAND         COMMAND"
    let rows = [
        // RSS and ELAPSED too wide for their columns; the padding of STAT and comm takes it up: args starts under its
        // header, and comm keeps its space.
        "   4242       1 postgres  1.2 12.5 1048576 123-01:02:03 Ssl tmux: server  tmux new -s main",
        // The same with a 15-character comm, which has no padding: args starts further right, and comm is taken to be
        // its first word.
        "   4243       1 postgres  1.2 12.5 1048576 123-01:02:03 Ssl+ postgres: walwr postgres: walwriter",
        // A line that ends after comm (not something ps prints) doesn't trip the parser.
        "   4244       1 root      0.0  0.0     0       00:01 S    kworker",
    ]
    let output = "Linux 6.1\n@@ps\n" + ([header] + rows).joined(separator: "\n") + "\n"
    let processes = Monitor.parse(output).snapshot.processes
    #expect(processes.map(\.pid) == [4242, 4243, 4244])
    #expect(processes.first?.name == "tmux: server" && processes.first?.command == "tmux new -s main")
    #expect(processes.first?.rss == 1048576 * 1024 && processes.first?.elapsed == 123 * 86400 + 3723)
    #expect(processes.dropFirst().first?.name == "postgres:")
    #expect(processes.dropFirst().first?.command == "walwr postgres: walwriter")
    #expect(processes.last?.name == "kworker" && processes.last?.command == "")
}

/// Plan S: a server with thousands of processes must not make refreshing slow (the parsing runs off the main thread,
/// but every 3 seconds). 5000 rows, 1.3 MB: about 10 ms in a release build, 50 ms in the tests' debug build (several
/// times that while the other tests run alongside).
@Test func fiveThousandProcessesParseQuickly() throws {
    let lines = debianOutput.components(separatedBy: "\n")
    let header = try #require(lines.first { $0.hasPrefix("    PID    PPID USER") })
    let templates = try [202, 203, 197, 162].map { pid in
        try #require(lines.first { $0.hasPrefix(String(format: "%7d ", pid)) })
    }
    let rows = (1...5000).map { pid in String(format: "%7d", pid) + templates[pid % templates.count].dropFirst(7) }
    let output = "Linux 6.12.48\n@@ps\n" + ([header] + rows).joined(separator: "\n") + "\n@@df\n"
    let clock = ContinuousClock()
    var reading = Monitor.Reading()
    let elapsed = clock.measure { reading = Monitor.parse(output) }
    #expect(reading.snapshot.processes.count == 5000)
    #expect(reading.snapshot.processes[0].name == "dd" && reading.snapshot.processes[1].name == "my sleeper")
    #expect(elapsed < .milliseconds(2000), "parsing 5000 processes took \(elapsed)")
}

/// The throwaway sshd runs on this Mac: not Linux.
@Test func monitorOnAServerThatIsNotLinux() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let monitor = Monitor(session: session)
        do {
            _ = try await monitor.refresh()
            Issue.record("this Mac was monitored as a Linux server")
        } catch let error as AirSCPError {
            #expect(error.message.hasPrefix("The system monitor works only on Linux servers (this one runs Darwin "))
        }
        #expect((await server.logEntries()).contains { $0.command.contains("@@stat") && $0.status == 0 })
        // Known from now on: no more commands.
        let count = await server.logEntries().count
        await #expect(throws: AirSCPError.self) { try await monitor.refresh() }
        #expect(await server.logEntries().count == count)

        // Kill and Force Kill are plain POSIX kill, so they work here too.
        for (force, signal) in [(false, SIGTERM), (true, SIGKILL)] {
            let ended = Recorder<Int32>()
            let pid = try Runner.start(["/bin/sleep", "120"], environment: [:], stderr: { _ in },
                                       exited: { ended.append($0) })
            defer { if ended.all.isEmpty { kill(pid, SIGKILL) } }  // not reaped yet, so the pid is still the sleep's
            try await monitor.kill(Int(pid), force: force)
            #expect(await eventually { ended.all == [128 + signal] }, "\(ended.all)")
        }
        #expect((await server.logEntries()).contains { $0.command.contains("kill -KILL ") })
        do {
            try await monitor.kill(99_999_999, force: false)
            Issue.record("killed a process that doesn't exist")
        } catch let error as AirSCPError {
            #expect(error.message == "Process 99999999 has already ended." && error.details.contains("No such process"))
        }
        if getuid() != 0 {
            do {
                try await monitor.kill(1, force: false)  // launchd: not this user's
                Issue.record("a user process could signal launchd")
            } catch let error as AirSCPError {
                #expect(error.kind == .permissionDenied && error.message == "This account may not stop process 1.")
            }
        }
        await #expect(throws: AirSCPError.self) { try await monitor.kill(0, force: true) }  // never a process group
        #expect(Monitor.sudoKillCommand([4242], force: false) == "sudo kill -TERM 4242")
        #expect(Monitor.sudoKillCommand([4242, 7], force: true) == "sudo kill -KILL 4242 7")
    }
}

@Test func monitorNeedsAShell() async throws {
    try await withServer(TestServer.Options(sftpOnly: true)) { server in
        let monitor = Monitor(session: try await server.connectedSession())
        do {
            _ = try await monitor.refresh()
            Issue.record("monitored an sftp-only account")
        } catch let error as AirSCPError {
            #expect(error.kind == .sftpOnly)
        }
    }
}

/// Bind mounts of one device are one disk; tmpfs (or overlay) file systems with the same name and figures are several.
@Test func onlyADevicesBindMountsAreOneDisk() {
    let output = "Linux 6.12.48\n@@df\nFilesystem 1024-blocks Used Available Capacity Mounted on\n"
        + "overlay 1000 10 990 1% /\n/dev/vda1 5000 100 4900 2% /etc/hosts\n/dev/vda1 5000 100 4900 2% /etc/hostname\n"
        + "tmpfs 4062512 1024 4061488 1% /mnt/@@ps\ntmpfs 4062512 1024 4061488 1% /mnt/café ✓\n"
        + "tmpfs 4062512 1024 4061488 1% /mnt/sp ace dir\n"
    #expect(Monitor.parse(output).snapshot.disks.map(\.mountPoint) == ["/", "/etc/hosts", "/mnt/@@ps", "/mnt/café ✓", "/mnt/sp ace dir"])
}
