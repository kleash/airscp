import Foundation
import Testing
@testable import AirSCPCore

// MARK: Quoting

@Test func shellQuoting() {
    #expect(Quote.shell("it's") == #"'it'\''s'"#)
    #expect(Quote.shell("") == "''")
    #expect(Quote.shellWord("/usr/bin/ssh") == "/usr/bin/ssh")
    #expect(Quote.shellWord("Port=22") == "Port=22")
    #expect(Quote.shellWord("a b") == "'a b'")
    #expect(Quote.shellWord("$HOME") == "'$HOME'")
    #expect(Quote.shellWord("") == "''")
}

@Test func sftpQuotingEscapesOnlyBackslashAndDoubleQuote() {
    #expect(Quote.sftp(#"/a\b"c"#) == #""/a\\b\"c""#)
    #expect(Quote.sftp("/x/*?[]{}'") == #""/x/*?[]{}'""#)
}

@Test func scpSourceEscapesGlobCharacters() {
    #expect(Quote.scpSource(#"/a\*b [1]?.txt"#) == #"/a\\\*b \[1\]\?.txt"#)
    #expect(Quote.scpSource("/plain name's \"x\"") == "/plain name's \"x\"")
}

@Test func configValueQuotesWhenNeeded() {
    #expect(Quote.configValue("/Users/me/.ssh/id") == "/Users/me/.ssh/id")
    #expect(Quote.configValue("/keys dir/id") == #""/keys dir/id""#)
    #expect(Quote.configValue(#"/a"b\c"#) == #""/a\"b\\c""#)
    #expect(Quote.configValue("a#b") == #""a#b""#)
}

// MARK: Command lines

private func sampleHost() -> SSHHost {
    var host = SSHHost(label: "Web", hostname: "web.example.com", port: 2222, username: "deploy", auth: .keyFile,
                    keyFile: "/Users/me/keys dir/id_ed25519")
    host.forwardAgent = true
    host.extraOptions = ["Compression=yes", " ", "# comment"]
    return host
}

/// The value after each "-o".
private func optionValues(_ argv: [String]) -> [String] {
    zip(argv, argv.dropFirst()).filter { $0.0 == "-o" }.map(\.1)
}

@Test func sharedOptionsAreOnlyDashO() {
    let options = OpenSSH.options(sampleHost(), jump: nil)
    #expect(options == ["-o", "Port=2222", "-o", "User=deploy", "-o", #"IdentityFile="/Users/me/keys dir/id_ed25519""#,
                        "-o", "IdentitiesOnly=yes", "-o", "ForwardAgent=yes", "-o", "Compression=yes"])
    var password = SSHHost(hostname: "h", auth: .password)
    password.port = nil
    #expect(OpenSSH.options(password, jump: nil) == ["-o", "PreferredAuthentications=keyboard-interactive,password"])
    #expect(OpenSSH.options(SSHHost(hostname: "h"), jump: nil).isEmpty)
}

@Test func noBareDashPForScpAndSftp() {
    let host = sampleHost(), socket = "/tmp/airscp-501/abc"
    let commands = [
        OpenSSH.sftpBatch(host, jump: nil, socket: socket),
        OpenSSH.upload("/l/f", to: "/r/f", folder: true, preserveTimes: false, host, jump: nil, socket: socket),
        OpenSSH.download("/r/f", to: "/l/f", folder: false, preserveTimes: false, host, jump: nil, socket: socket),
        OpenSSH.copyID("/k.pub", host, jump: nil),
    ]
    for argv in commands {
        #expect(!argv.contains("-p"), "\(argv)")
        #expect(!argv.contains("-P"), "\(argv)")
        #expect(optionValues(argv).contains("Port=2222"))
    }
    // With "preserve times", -p appears once, as scp's flag before the options.
    let preserving = OpenSSH.upload("/l/f", to: "/r/f", folder: false, preserveTimes: true, host, jump: nil, socket: socket)
    #expect(preserving.filter { $0 == "-p" }.count == 1)
    #expect(preserving.firstIndex(of: "-p")! < preserving.firstIndex(of: "-o")!)
}

@Test func muxedCommandsUseBatchModeAndTheSocket() {
    _ = TestEnvironment.isolated  // the -F seam, with no default key files (IdentityFile=none)
    let host = sampleHost(), socket = "/tmp/airscp-501/0123456789ab"
    for argv in [OpenSSH.sftpBatch(host, jump: nil, socket: socket),
                 OpenSSH.remote("true", host, jump: nil, socket: socket),
                 OpenSSH.upload("/a", to: "/b", folder: false, preserveTimes: false, host, jump: nil, socket: socket),
                 OpenSSH.download("/a", to: "/b", folder: false, preserveTimes: false, host, jump: nil, socket: socket)] {
        let values = optionValues(argv)
        #expect(values.prefix(4) == ["IdentityFile=none", "ControlMaster=no", "ControlPath=\(socket)", "BatchMode=yes"])
    }
}

@Test func masterCommand() {
    let argv = OpenSSH.master(sampleHost(), jump: nil, socket: "/s")
    #expect(argv.prefix(3) == ["/usr/bin/ssh", "-M", "-N"])
    let values = optionValues(argv)
    for option in ["ControlPath=/s", "ControlPersist=no", "ConnectTimeout=15", "ServerAliveInterval=15", "ServerAliveCountMax=3"] {
        #expect(values.contains(option))
    }
    #expect(argv.last == "web.example.com")
    #expect(OpenSSH.control("check", sampleHost(), jump: nil, socket: "/s").contains("check"))
    let forward = OpenSSH.control("forward", sampleHost(), jump: nil, socket: "/s",
                                   forward: Tunnel(kind: .local, listenPort: 8080, targetHost: "db", targetPort: 5432).forwardArguments)
    #expect(forward.contains("-L") && forward.contains("127.0.0.1:8080:db:5432"))
}

@Test func jumpHostBecomesAProxyCommand() {
    _ = TestEnvironment.isolated  // tests run in parallel: the -F seam may be set by now, so set it
    var jump = SSHHost(hostname: "bastion.example.com", port: 2200, username: "me", auth: .keyFile, keyFile: "/k%dir/id")
    jump.extraOptions = ["User=other"]
    let options = optionValues(OpenSSH.options(SSHHost(hostname: "inner"), jump: jump))
    let proxy = try! #require(options.first { $0.hasPrefix("ProxyCommand=") })
    #expect(proxy == "ProxyCommand=/usr/bin/ssh -F \(TestEnvironment.sshConfig) -o IdentityFile=none -o ConnectTimeout=15 -o Port=2200 -o User=me "
        + "-o IdentityFile=/k%%%%dir/id -o IdentitiesOnly=yes -o User=other -W %h:%p bastion.example.com")
    // An automatic reconnect tries one password at most, on the jump host too.
    for silent in [false, true] {
        let master = optionValues(OpenSSH.master(SSHHost(hostname: "inner"), jump: jump, socket: "/s", silent: silent))
        let hop = try! #require(master.first { $0.hasPrefix("ProxyCommand=") })
        #expect(master.contains("NumberOfPasswordPrompts=1") == silent)
        #expect(hop.hasPrefix("ProxyCommand=/usr/bin/ssh -F \(TestEnvironment.sshConfig) -o IdentityFile=none "
            + (silent ? "-o NumberOfPasswordPrompts=1 -o ConnectTimeout=15 -o Port=2200" : "-o ConnectTimeout=15 -o Port=2200")))
        // The connect timeout is the first hop's: through it, ssh's own would also run while the user answers the jump
        // host's questions (its password, its host key).
        #expect(!master.contains("ConnectTimeout=15"))
    }
    // Through a proxy: no ssh timeout at all (the proxy's password may be asked for); a jump host behind a proxy too.
    var proxied = SSHHost(hostname: "inner")
    proxied.proxyID = UUID()
    #expect(!optionValues(OpenSSH.master(proxied, jump: nil, socket: "/s")).contains("ConnectTimeout=15"))
    var proxiedJump = jump
    proxiedJump.proxyID = UUID()
    let viaProxy = optionValues(OpenSSH.master(SSHHost(hostname: "inner"), jump: proxiedJump, socket: "/s"))
    #expect(!viaProxy.contains { $0.contains("ConnectTimeout") })
}

@Test func transferOperands() {
    let host = SSHHost(hostname: "fe80::1"), socket = "/s"
    let up = OpenSSH.upload("/local/a b", to: "/remote/x*y[1]", folder: false, preserveTimes: false, host, jump: nil, socket: socket)
    #expect(up.suffix(3) == ["--", "/local/a b", "[fe80::1]:/remote/x*y[1]"])
    let down = OpenSSH.download("/remote/x*y[1]", to: "/local/x", folder: true, preserveTimes: false, host, jump: nil, socket: socket)
    #expect(down.suffix(3) == ["--", #"[fe80::1]:/remote/x\*y\[1\]"#, "/local/x"])
    #expect(down.contains("-r"))
    #expect(OpenSSH.sftpBatch(host, jump: nil, socket: socket).last == "[fe80::1]")
    #expect(OpenSSH.remote("ls", host, jump: nil, socket: socket).suffix(2) == ["fe80::1", "ls"])
}

@Test func terminalCommand() {
    let host = SSHHost(hostname: "h", port: 22)
    let argv = OpenSSH.terminal(host, jump: nil, socket: "/tmp/airscp-501/abc", command: OpenSSH.shellIn("/srv/it's here"))
    #expect(argv.first == "/usr/bin/ssh" && argv.contains("ControlPath=/tmp/airscp-501/abc") && argv.contains("ControlMaster=no"))
    // The remote command is one word holding `cd '<dir>' && exec "$SHELL" -l` for sh, after -t and the host (how every
    // login shell hands it on: viaShHandsAServerNameToShUnreadByAnyLoginShell). (Terminal's script around it:
    // TerminalLauncher.script, in ShellTests.)
    #expect(argv.suffix(3) == ["-t", "h", OpenSSH.viaSh(#"cd '/srv/it'\''s here' && exec "$SHELL" -l"#)])
    #expect(!OpenSSH.terminal(host, jump: nil, socket: "/s").contains("-t"))
}

@Test func keyCommands() {
    _ = TestEnvironment.isolated
    #expect(OpenSSH.generateKey(.ed25519, format: .openSSH, path: "/t/k", comment: "me")
            == ["/usr/bin/ssh-keygen", "-t", "ed25519", "-C", "me", "-f", "/t/k"])
    let rsa = Keys.Kind.all.first { $0.id == "rsa-4096" }!
    #expect(OpenSSH.generateKey(rsa, format: .pem, path: "/t/k", comment: "")
            == ["/usr/bin/ssh-keygen", "-t", "rsa", "-b", "4096", "-m", "PEM", "-C", "", "-f", "/t/k"])
    let ecdsa = Keys.Kind.all.first { $0.id == "ecdsa-384" }!
    #expect(OpenSSH.generateKey(ecdsa, format: .pkcs8, path: "/t/k", comment: "c")
            == ["/usr/bin/ssh-keygen", "-t", "ecdsa", "-b", "384", "-m", "PKCS8", "-C", "c", "-f", "/t/k"])
    #expect(OpenSSH.exportPublicKey("/t/k.pub", format: "RFC4716") == ["/usr/bin/ssh-keygen", "-e", "-m", "RFC4716", "-f", "/t/k.pub"])
    // A passphrase is never in a command line: only the empty one that removes it.
    #expect(OpenSSH.changePassphrase("/t/k", removing: false) == ["/usr/bin/ssh-keygen", "-p", "-f", "/t/k"])
    #expect(OpenSSH.changePassphrase("/t/k", removing: true) == ["/usr/bin/ssh-keygen", "-p", "-N", "", "-f", "/t/k"])
    #expect(OpenSSH.fingerprint("/t/k.pub") == ["/usr/bin/ssh-keygen", "-l", "-f", "/t/k.pub"])
    #expect(OpenSSH.removeHostKey("[h]:2222", knownHosts: "/t/kh") == ["/usr/bin/ssh-keygen", "-R", "[h]:2222", "-f", "/t/kh"])
    // -f only when the host already logs in with a key file.
    #expect(OpenSSH.copyID("/k.pub", sampleHost(), jump: nil).contains("-f"))
    #expect(!OpenSSH.copyID("/k.pub", SSHHost(hostname: "h", auth: .password), jump: nil).contains("-f"))
    #expect(OpenSSH.resolve(SSHHost(hostname: "alias"), jump: nil)
            == ["/usr/bin/ssh", "-G", "-F", TestEnvironment.sshConfig, "-o", "IdentityFile=none", "alias"])
}

@Test func tunnelForwardArguments() {
    #expect(Tunnel(kind: .local, listenPort: 8080, targetHost: "localhost", targetPort: 80).forwardArguments
            == ["-L", "127.0.0.1:8080:localhost:80"])
    #expect(Tunnel(kind: .remote, listenPort: 9000, targetHost: "::1", targetPort: 22).forwardArguments == ["-R", "9000:[::1]:22"])
    #expect(Tunnel(kind: .dynamic, listenPort: 1080).forwardArguments == ["-D", "127.0.0.1:1080"])
}

@Test func shellLineForTheLog() {
    #expect(Runner.shellLine(["/usr/bin/sftp", "-b", "-", "-o", "User=a b", "h"], input: "ls -lan \"/x\"\nrm \"/it's\"\n")
        == #"printf '%s\n' 'ls -lan "/x"' 'rm "/it'\''s"' | /usr/bin/sftp -b - -o 'User=a b' h"#)
}

// MARK: Sentinel

@Test func sentinelParsing() {
    let noisy = "Welcome!\nlast login: today\n\n__AIRSCP__\nline 1\nline 2\n\n__AIRSCP_RC__=0\nbye\n"
    let parsed = try! #require(OpenSSH.parseSentinel(noisy))
    #expect(parsed.output == "line 1\nline 2\n")
    #expect(parsed.status == 0)
    #expect(OpenSSH.parseSentinel("\n__AIRSCP__\n\n__AIRSCP_RC__=17\n")! == ("", 17))
    #expect(OpenSSH.parseSentinel("This service allows sftp connections only.\n") == nil)
    // Output that itself mentions the end marker: the last one counts.
    #expect(OpenSSH.parseSentinel("\n__AIRSCP__\na\n__AIRSCP_RC__=9\nb\n\n__AIRSCP_RC__=0\n")?.output == "a\n__AIRSCP_RC__=9\nb\n")
}

@Test func sentinelScriptRunsInSh() async {
    // The production path: the login shell gets only `exec sh -s`, and the wrapped script is piped to sh on standard
    // input (so no server-supplied byte reaches the login shell's command line). Any POSIX shell must run it.
    let (command, input) = OpenSSH.longScript(OpenSSH.sentinelScript("printf '%s\\n' \"it's\"; false"))
    #expect(command == "exec sh -s")
    let result = await Runner.run(["/bin/sh", "-c", "echo noise; " + command], input: input)
    let parsed = OpenSSH.parseSentinel(result.output)
    #expect(parsed?.output == "it's\n")
    #expect(parsed?.status == 1)
}

// MARK: Server names never reach the login shell's command line

/// Every remote shell script is piped to `sh` on standard input: the login shell sees only `exec sh -s`, so a name a
/// server supplies (embedded in the script with POSIX quoting) is parsed by a POSIX `sh`, not by a login shell that
/// might mis-read it (fish, csh, tcsh). `longScript` has no `exec sh -c` branch, whatever the script's length.
@Test func longScriptAlwaysPipesTheScriptToSh() {
    #expect(OpenSSH.longScript("rm -rf -- 'x'") == ("exec sh -s", "rm -rf -- 'x'\n"))
    let big = String(repeating: "echo hi; ", count: 10_000)
    let (command, input) = OpenSSH.longScript(big)
    #expect(command == "exec sh -s" && input == big + "\n")
}

/// A tar consumer unpacks into a server-supplied folder. The folder must not reach the login shell's command line — a
/// non-POSIX login shell mis-reads even a correctly single-quoted name there — so the login shell gets only a fixed
/// script that reads the folder from standard input (`read`), and the folder travels in the preamble the pump writes
/// before the archive. The fixed script holds no backslash, "!" or newline, so every login shell quotes it safely.
@Test func tarConsumerKeepsTheServerFolderOffTheCommandLine() throws {
    _ = TestEnvironment.isolated
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let session = Session(host: SSHHost(hostname: "h"), jump: nil, askpass: askpass)
    let folder = "/srv/sq'uote back\\slash star* dir/.airscp-1234abcd.part"
    let (argv, preamble) = try TransferQueue.consumer(unpack: "tar -xpf - && exec cat >/dev/null", folder: folder, on: session)
    let command = try #require(argv.last)
    #expect(command.hasPrefix("exec sh -c ") && command.contains("IFS= read -r d"))
    #expect(!command.contains(folder) && !command.contains("sq'uote") && !command.contains("back\\slash"))
    #expect(!command.contains("\\") && !command.contains("!") && !command.contains("\n"))
    #expect(preamble == Data((folder + "\n").utf8))
    // `read` stops at a line break: such a folder is refused (the cut path would be another folder for rm -rf).
    #expect(throws: AirSCPError.self) {
        try TransferQueue.consumer(unpack: "tar -xpf -", folder: "/srv/a\nb/.airscp-1234abcd.part", on: session)
    }
}

/// Commands with a terminal (Open Terminal Here, Run in Terminal of File ▸ Run…) can't take a script on standard input
/// (the keyboard), so `viaSh` puts the command on the login shell's command line as printf's octal escapes. Every
/// shell this Mac has — POSIX ones and csh/tcsh, which mis-read POSIX quoting — hands it to sh unchanged: names with
/// quotes, backslashes, "!", "$(…)", line breaks and non-ASCII come out as they went in, and none runs anything.
/// (fish, which this Mac lacks, was checked the same way in a container: docs/dev/regression-history.md.)
@Test func viaShHandsAServerNameToShUnreadByAnyLoginShell() async throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    /// `shell -c line` started in `dir` (where a name that ran a command would leave a file), with `environment`.
    func run(_ shell: String, _ line: String, environment: [String: String] = [:]) async -> String {
        await Runner.run(["/bin/sh", "-c", "cd \"$1\" && exec \"$2\" -c \"$3\"", "sh", dir, shell, line],
                         environment: environment).output
    }
    let awkward = ["x\\';touch PWNED1;#", "a'b\"c$(touch PWNED2)`touch PWNED3`!!x", "line\nbreak; touch PWNED4",
                   "ünï %s %n \\ \\\\ end\n", "-dash", "*", "~", "!1", "a\\'\\\\'b'"]
    for name in awkward {
        let line = OpenSSH.viaSh("printf '%s|' " + Quote.shell(name))
        // Only letters, digits, spaces and \ " $ ( ) between the two single quotes, a backslash only before digits.
        #expect(line.filter { $0 == "'" }.count == 2 && !line.contains("!") && !line.contains("\n"))
        #expect(line.range(of: "\\\\[^0-7]", options: .regularExpression) == nil)
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/ksh", "/bin/csh", "/bin/tcsh"] {
            #expect(await run(shell, line) == name + "|", "\(shell): \(name)")
        }
    }
    #expect(names(in: dir).isEmpty, "a name ran a command")
    // Open Terminal Here: the login shell ($SHELL, here a script printing its folder) starts in the folder.
    let folder = dir + "/sq'uote \\';touch PWNED;# dir"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
    let login = dir + "/login"
    try "#!/bin/sh\npwd\n".write(toFile: login, atomically: true, encoding: .utf8)
    chmod(login, 0o755)
    for shell in ["/bin/zsh", "/bin/csh", "/bin/tcsh"] {
        #expect(await run(shell, OpenSSH.shellIn(folder), environment: ["SHELL": login]) == folder + "\n", "\(shell)")
    }
    #expect(names(in: dir) == ["login", "sq'uote \\';touch PWNED;# dir"])
}

// MARK: Parsers

@Test func listingParser() throws {
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12))!
    let output = """
        sftp> cd "/srv/www"
        sftp> ls -lan
        drwxr-xr-x    ? 1000     1000         4096 Oct  2 11:39 .
        drwxr-xr-x    ? 0        0            4096 Jan  1  2024 ..
        -rw-r--r--    ? 1000     1000        16441 Oct  2 11:39 index.html
        -rw-r--r--    ? 1000     1000            7 Sep 30 08:01  leading space.txt
        lrwxrwxrwx    ? 1000     1000           11 Mar  5  2025 current -> ignored?
        -rwsr-x--T    ? sa       Domain Users    0 Dec 31 23:59 setuid
        drwxrwxrwt+   ? 0        0               0 Oct  3 10:00 future
        -rw-r--r--    ? 0        0               5 Oct  1 10:00 a name with
        a newline in it
        -rw-r--r--    ? 0        0               5 Oct  1 10:00 trailing newline

        crw-rw-rw-    ? 0        0               0 Oct  1 10:00 null
        """
    let entries = Listing.parse(output + "\n", in: "/srv/www", now: now)
    // The names with newlines are left out: their first line parses, but with the name cut off.
    #expect(entries.map(\.name) == ["index.html", " leading space.txt", "current -> ignored?", "setuid", "future", "null"])
    let index = entries[0]
    #expect(index.path == "/srv/www/index.html")
    #expect(index.kind == .file && index.size == 16441 && index.mode == 0o644 && index.owner == "1000" && index.group == "1000")
    let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: index.modified!)
    #expect(components == DateComponents(year: 2026, month: 10, day: 2, hour: 11, minute: 39))
    #expect(entries[2].kind == .symlink)
    // A day only ("Mar  5  2025"): that day's midnight in UTC, whatever the time zone sftp printed it in.
    #expect(entries[2].dateOnly && entries[2].modified == Date(timeIntervalSince1970: 1_741_132_800) && !index.dateOnly)
    #expect(entries[3].mode == 0o4750 | 0o1000)
    #expect(entries[3].owner == "sa" && entries[3].group == "Domain Users")
    // Dec 31 23:59 "in the future" is last year's.
    #expect(Calendar.current.component(.year, from: entries[3].modified!) == 2025)
    #expect(entries[4].kind == .directory && entries[4].mode == 0o1777)
    #expect(entries[5].kind == .other)
    #expect(Listing.parse("-rw-r--r--    ? 0 0 1 Oct  2 11:39 x", in: "/", now: now).first?.path == "/x")
}

@Test func progressParser() {
    var parser = ProgressParser()
    let frames = "\rbig file.bin                       48%   14MB   5.8MB/s   00:02 ETA"
        + "\rbig file.bin                      100%   30MB  12.3MB/s   00:02    \r\n"
        + "\rnext 50% off                        3%  1023KB 200.0KB/s   --:-- ETA"
    // Split mid-frame and mid-character.
    let data = Data(frames.utf8)
    let returns = data.indices.filter { data[$0] == 0x0D }
    #expect(parser.feed(data.prefix(20)) == false)
    // A whole frame is shown as soon as it is in, before the next frame's "\r" ends it.
    _ = parser.feed(data[20..<returns[1]])
    #expect(parser.progress.percent == 48)
    _ = parser.feed(data[returns[1]..<(returns[1] + 3)])
    #expect(parser.progress.percent == 48)
    #expect(parser.progress.file == "big file.bin")
    #expect(parser.progress.bytes == 14 * 1024 * 1024)
    #expect(parser.progress.speed == "5.8MB/s" && parser.progress.eta == "00:02")
    _ = parser.feed(data[(returns[1] + 3)...])
    #expect(parser.progress.filesDone == 1)
    _ = parser.feed(Data("\r".utf8))
    #expect(parser.progress.file == "next 50% off" && parser.progress.percent == 3 && parser.progress.eta == "--:--")
    #expect(parser.progress.bytes == 1023 * 1024)
    #expect(ProgressParser.bytes("0") == 0 && ProgressParser.bytes("2") == 2 && ProgressParser.bytes("1.5GB") == 1_610_612_736)
}

@Test func fingerprintParser() {
    let parsed = Keys.parseFingerprint("256 SHA256:OeLf9gLC53M7vG1cw6 me@mac (ED25519)\n")
    #expect(parsed?.bits == 256 && parsed?.fingerprint == "SHA256:OeLf9gLC53M7vG1cw6")
    #expect(parsed?.comment == "me@mac" && parsed?.type == "ED25519")
    #expect(Keys.parseFingerprint("4096 SHA256:x a comment with spaces (RSA)")?.comment == "a comment with spaces")
    #expect(Keys.parseFingerprint("256 SHA256:x (ED25519)")?.comment == "")
    #expect(Keys.parseFingerprint("not a key") == nil)
}

@Test func sshConfigAliases() {
    let text = """
        Host web db.internal
          HostName 10.0.0.1
        Host *.example.com !bad ?x
        host=eqalias # trailing comment
        Match host foo
        Host "quoted" web
        # Host commented
        """
    #expect(SSHConfig.aliases(in: text) == ["web", "db.internal", "eqalias", "quoted"])
}

@Test func sshDashGParser() {
    let output = """
        user deploy
        hostname 10.0.0.5
        port 2222
        identityfile ~/.ssh/id_rsa
        userknownhostsfile /Users/me/.ssh/known_hosts /Users/me/.ssh/known_hosts2
        proxyjump none
        """
    let resolved = SSHConfig.parse(output)
    #expect(resolved?.hostname == "10.0.0.5" && resolved?.user == "deploy" && resolved?.port == 2222)
    #expect(resolved?.knownHostsFiles == ["/Users/me/.ssh/known_hosts", "/Users/me/.ssh/known_hosts2"])
    #expect(resolved?.proxyJump == nil && resolved?.hostKeyAlias == nil)
}

// MARK: Errors and prompts

@Test func errorMapping() {
    func kind(_ text: String) -> AirSCPError.Kind { ErrorMapping.map(text, status: 255).kind }
    #expect(kind("ssh: connect to host 127.0.0.1 port 2: Connection refused") == .refused)
    #expect(kind("ssh: Could not resolve hostname nope: nodename nor servname provided, or not known") == .unknownHost)
    #expect(kind("ssh: connect to host 10.255.255.1 port 22: Operation timed out") == .timeout)
    #expect(kind("ssh: connect to host 10.0.0.1 port 22: No route to host") == .noRoute)
    #expect(kind("sa@127.0.0.1: Permission denied (publickey,password).") == .authFailed(methods: "publickey,password"))
    #expect(kind("Received disconnect from 1.2.3.4 port 22:2: Too many authentication failures") == .tooManyAuthFailures)
    // Wrong passwords, or a key file that isn't there, may end in "Too many authentication failures" too: the
    // message says what really went wrong, not "too many keys".
    let wrongPassword = ErrorMapping.map("Permission denied, please try again.\r\nPermission denied, please try again.\r\n"
        + "Received disconnect from 127.0.0.1 port 42201:2: Too many authentication failures\r\n"
        + "Disconnected from 127.0.0.1 port 42201", status: 255)
    #expect(wrongPassword.kind == .authFailed(methods: "")
            && wrongPassword.message == "The server didn't accept the user name or password. Check the user name in the "
                + "host's settings (Host ▸ Edit…), then try the password again.")
    #expect(kind("Permission denied, please try again.\ndev@h: Permission denied (publickey,password).")
            == .authFailed(methods: "publickey,password"))
    let missingKey = ErrorMapping.map("no such identity: /tmp/keys/gone_key: No such file or directory\r\n"
        + "Received disconnect from 127.0.0.1 port 42201:2: Too many authentication failures", status: 255,
        keyFiles: ["/tmp/keys/gone_key"])
    #expect(missingKey.kind == .authFailed(methods: "")
            && missingKey.message == "The key file /tmp/keys/gone_key doesn't exist (any more). Choose another key in the host's settings.")
    // A missing key file the host doesn't name (~/.ssh/config's Host * IdentityFile) isn't why its login failed.
    let elsewhere = ErrorMapping.map("no such identity: /tmp/keys/config_key: No such file or directory\r\n"
        + "dev@127.0.0.1: Permission denied (publickey,password).", status: 255, keyFiles: ["/tmp/keys/id_host"])
    #expect(elsewhere.kind == .authFailed(methods: "publickey,password") && !elsewhere.message.contains("key file"))
    #expect(ErrorMapping.map("command-line: line 0: Bad configuration option: bogus", status: 255).message
            == "“bogus” isn't an ssh option: check the host's Other ssh options (Advanced).")
    #expect(ErrorMapping.map("End-of-central-directory signature not found.  Either this file is not\n  a zipfile, or it "
        + "constitutes one disk of a multi-part archive.\nunzip:  cannot find zipfile directory in one of a.zip", status: 9).message
            == "It isn't a zip archive, or it is damaged.")
    #expect(kind("This service allows sftp connections only.") == .sftpOnly)
    #expect(kind("@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\nHost key verification failed.") == .hostKeyChanged)
    #expect(kind("Host key verification failed.") == .hostKeyRejected)
    #expect(kind("remote delete /x: Permission denied") == .permissionDenied)
    #expect(kind("/usr/bin/scp: dest open \"/ro/a.txt\": Permission denied") == .permissionDenied)
    #expect(kind("remote delete /x: No such file or directory") == .noSuchFile)
    #expect(kind("Can't ls: \"/x\" not found") == .noSuchFile)
    #expect(kind("realpath /nope/nothing: No such file") == .noSuchFile)  // sftp's cd into a folder that isn't there
    #expect(ErrorMapping.map("download /home/dev/pipe: not a regular file", status: 1).message.hasPrefix("It isn't a file or a folder"))
    #expect(kind("remote rmdir \"/d\": Failure") == .failure)
    #expect(kind("/usr/bin/scp: write remote \"/x\": Failure") == .diskFull)
    #expect(kind("cp: error writing '/x': No space left on device") == .diskFull)
    #expect(kind("Control socket connect(/tmp/airscp-501/abc): Connection refused") == .disconnected)
    #expect(kind("mux_client_request_session: session request failed: Session open refused by peer") == .busy)
    #expect(kind("mux_client_forward: forwarding request failed: Port forwarding failed") == .portInUse)
    let other = ErrorMapping.map("something odd\nmore", status: 3)
    #expect(other.kind == .other && other.message == "something odd" && other.details == "something odd\nmore")
    #expect(ErrorMapping.map("", status: 3).details == "Exit status 3")

    // Only ssh's own lines say the connection is gone: a file's name in an error doesn't.
    #expect(kind("remote delete /home/dev/cs/Control socket connect: Permission denied") == .permissionDenied)
    #expect(kind("remote delete /home/dev/cs/Broken pipe.txt: Permission denied") == .permissionDenied)
    #expect(kind("rm: cannot remove 'Connection reset by peer': Permission denied") == .permissionDenied)
    #expect(!ErrorMapping.masterGone("remote delete /x/Control socket connect: Permission denied"))
    #expect(ErrorMapping.masterGone("Control socket connect(/tmp/airscp-501/abc): No such file or directory"))
    #expect(kind("client_loop: send disconnect: Broken pipe") == .disconnected)
    #expect(kind("Connection to 10.0.0.1 closed by remote host.") == .disconnected)
    #expect(kind("mux_client_request_session: write packet: Broken pipe") == .disconnected)
    // This Mac's failures are this Mac's.
    #expect(ErrorMapping.map("/usr/bin/scp: write local \"/v/dl.part\": No space left on device", status: 1).message
            == "There isn't enough space on this Mac for the download.")
    #expect(ErrorMapping.map("/usr/bin/scp: open local \"/ro/x\": Permission denied", status: 1).message
            == "AirSCP may not write or read that file on this Mac.")
    #expect(ErrorMapping.mapLocal("tar: Write failed: No space left on device", status: 1).message
            == "There isn't enough space on this Mac for the download.")
    #expect(ErrorMapping.map("remote mkdir \"/ro/x\": Failure", status: 1).message.contains("read-only disk"))
    // Through a jump host: the far side's words, and ssh's notes are no reason.
    let behindJump = ErrorMapping.map("Warning: Permanently added '[127.0.0.1]:42203' (ED25519) to the list of known hosts.\r\n"
        + "channel 0: open failed: connect failed: Name does not resolve\r\nstdio forwarding failed", status: 255)
    #expect(behindJump.kind == .unknownHost && !behindJump.message.contains("Permanently"))
    #expect(ErrorMapping.map("Warning: Permanently added 'h' (ED25519) to the list of known hosts.\nweird failure", status: 1).message
            == "weird failure")
}

@Test func promptClassification() {
    let hostKey = """
        The authenticity of host '[127.0.0.1]:58701 ([127.0.0.1]:58701)' can't be established.
        ED25519 key fingerprint is: SHA256:wq/DEkLPz5TGMXMO5RO8e5z0ieCRuNN+NIDXdnCkqZ4
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?\u{20}
        """
    #expect(Askpass.classify(hostKey) == .hostKey(host: "[127.0.0.1]:58701", fingerprint: "SHA256:wq/DEkLPz5TGMXMO5RO8e5z0ieCRuNN+NIDXdnCkqZ4"))
    #expect(Askpass.classify("sa@127.0.0.1's password: ") == .password(user: "sa", host: "127.0.0.1"))
    #expect(Askpass.classify("(deploy@web.example.com) Password: ") == .password(user: "deploy", host: "web.example.com"))
    #expect(Askpass.classify("Password:") == .password(user: nil, host: nil))
    #expect(Askpass.classify("Enter passphrase for key '/Users/me/.ssh/id_ed25519': ") == .passphrase)
    #expect(Askpass.classify("Enter passphrase for \"/t/k\" (empty for no passphrase): ") == .passphrase)
    #expect(Askpass.classify("Enter same passphrase again: ") == .passphrase)
    #expect(Askpass.classify("(me@host) Verification code: ") == .other)
}

@Test func passwordPromptsGoToTheHostTheyName() throws {
    let askpass = try AskpassServer(helperPath: "/usr/bin/false")
    defer { askpass.close() }
    let target = SSHHost(hostname: "inner.lan", username: "app")
    let jump = SSHHost(hostname: "Bastion.example.com", username: "me")
    let direct = Session(host: target, jump: nil, askpass: askpass)
    #expect(direct.promptTarget(user: "whoever", host: "anything")?.id == target.id)
    #expect(direct.promptTarget(user: nil, host: nil)?.id == target.id)
    let hopping = Session(host: SSHHost(id: target.id, hostname: "inner.lan", username: "app"), jump: jump, askpass: askpass)
    #expect(hopping.promptTarget(user: "me", host: "bastion.example.com")?.id == jump.id)
    #expect(hopping.promptTarget(user: "app", host: "inner.lan")?.id == target.id)
    #expect(hopping.promptTarget(user: "root", host: "bastion.example.com") == nil)
    #expect(hopping.promptTarget(user: nil, host: nil) == nil)
}

// MARK: Names and paths

@Test func conflictNamesCompareCanonically() {
    let nfc = "caf\u{E9}.txt", nfd = "cafe\u{301}.txt"
    #expect(Array(nfc.utf8) != Array(nfd.utf8))
    #expect(Names.existing(nfc, in: ["a", nfd]) == nfd)  // the existing spelling, to replace exactly that file
    #expect(Names.existing("README", in: ["readme"]) == nil)
    #expect(Names.existing("README", in: ["readme"], caseInsensitive: true) == "readme")
    #expect(Names.unique("a.txt", existing: ["b"]) == "a.txt")
    #expect(Names.unique("a.txt", existing: ["a.txt", "a 2.txt"]) == "a 3.txt")
    #expect(Names.unique("logs.tar.gz", existing: ["logs.tar.gz"]) == "logs 2.tar.gz")
    #expect(Names.unique(".bashrc", existing: [".bashrc"]) == ".bashrc 2")
    #expect(Names.unique("folder", existing: ["folder"]) == "folder 2")
    // A name made from a 255-byte one is shortened before its extension: the tools refused it ("File name too long").
    let long = String(repeating: "L", count: 251) + ".txt"
    #expect(Names.unique(long, existing: [long]) == String(repeating: "L", count: 249) + " 2.txt")
    #expect(Names.unique(long + ".zip", existing: []) == String(repeating: "L", count: 251) + ".zip")
    let accents = String(repeating: "\u{E9}", count: 125) + ".txt"  // 254 bytes: shortened by whole characters
    #expect(Names.unique(accents, existing: [accents]).utf8.count <= 255 && Names.unique(accents, existing: [accents]).hasSuffix("\u{E9} 2.txt"))
    // Names that differ only in case, or in their Unicode form (by their bytes: both forms kept), clash in an archive.
    let clashes = TransferQueue.clashes(["caf\u{E9}.txt", "cafe\u{301}.txt", "other", "README", "readme", "other"], ignoringCase: true)
    #expect(Set(clashes.map { Data($0.utf8) }) == Set(["caf\u{E9}.txt", "cafe\u{301}.txt", "README", "readme"].map { Data($0.utf8) }))
    #expect(Names.unique(nfc, existing: [nfd]) == "caf\u{E9} 2.txt")
}

@Test func remotePaths() {
    #expect(RemotePath.join("/", "a") == "/a")
    #expect(RemotePath.join("/srv/", "a") == "/srv/a")
    #expect(RemotePath.join("/srv", "a") == "/srv/a")
    #expect(RemotePath.parent("/srv/www/") == "/srv")
    #expect(RemotePath.parent("/srv") == "/")
    #expect(RemotePath.parent("/") == "/")
    #expect(RemotePath.name("/srv/www/") == "www")
    #expect(ArchiveKind.baseName("logs.TAR.GZ") == "logs")
    #expect(ArchiveKind.baseName("a.zip") == "a" && ArchiveKind.baseName("notes.txt.gz") == "notes.txt")
    #expect(Session.isArchive("x.tgz") && Session.isArchive("x.tar.xz") && Session.isArchive("x.gz") && !Session.isArchive("x.txt"))
}

// MARK: Storage

@Test func storeRoundTripAndTolerance() throws {
    let dir = try scratch()
    setenv("AIRSCP_SUPPORT_DIR", dir, 1)
    #expect(Store.directory.path == dir)
    #expect(Store.load() == AirSCPData())

    var data = AirSCPData()
    var host = sampleHost()
    host.tunnels = [Tunnel(kind: .dynamic, listenPort: 1080)]
    data.hosts = [host]
    data.groups = [HostGroup(name: "Prod")]
    data.snippets = [Snippet(name: "Disk", command: "df -h", runInTerminal: true)]
    data.settings.showHidden = true
    try Store.save(data)
    #expect(Store.load() == data)

    // A file from another version: unknown keys ignored, missing settings take their defaults.
    try #"{"hosts": [], "settings": {"showHidden": true, "futureKey": 1}, "future": []}"#
        .write(toFile: dir + "/airscp.json", atomically: true, encoding: .utf8)
    let loaded = Store.load()
    #expect(loaded.settings.showHidden && loaded.settings.confirmDelete && loaded.snippets.isEmpty)

    // An unreadable file is moved aside, not overwritten.
    try "{ not json".write(toFile: dir + "/airscp.json", atomically: true, encoding: .utf8)
    #expect(Store.load() == AirSCPData())
    #expect(read(dir + "/airscp.json.unreadable") == "{ not json")

    // Export and import: hosts, groups, proxies and Remote Desktop entries (not snippets or settings); same ids
    // replace. A key file in the home folder goes as ~/…, for the other Mac's home folder.
    host.keyFile = NSHomeDirectory() + "/.ssh/id_work"
    host.lastLocalDir = NSHomeDirectory() + "/Projects"
    data.hosts = [host]
    data.proxies = [Proxy(name: "office", host: "proxy.example", port: 3128, username: "me")]
    data.rdpEntries = [RDPEntry(label: "Windows", hostname: "win.example")]
    let exported = try Store.export(data)
    var other = AirSCPData(hosts: [SSHHost(id: host.id, label: "old")], snippets: [Snippet(name: "mine", command: "true")])
    other.merge(try Store.importHosts(from: exported))
    var portable = host
    portable.keyFile = "~/.ssh/id_work"
    portable.lastLocalDir = nil  // this Mac's folder, and its user name: not in the file
    let json = String(decoding: exported, as: UTF8.self)
    #expect(!json.contains("\"settings\"") && !json.contains("\"snippets\"") && !json.contains(NSHomeDirectory()), "\(json)")
    #expect(other.hosts == [portable] && other.groups == data.groups && other.proxies == data.proxies)
    #expect(other.rdpEntries == data.rdpEntries && other.snippets.map(\.name) == ["mine"] && !other.settings.showHidden)
}

/// AirSCP was called Porter (PLAN.md X). Its environment variables still answer to their PORTER_ names; AIRSCP_ wins.
@Test func environmentVariablesStillTakeTheirPorterNames() {
    #expect(Env.value("SUPPORT_DIR", in: ["AIRSCP_SUPPORT_DIR": "/a"]) == "/a")
    #expect(Env.value("SUPPORT_DIR", in: ["PORTER_SUPPORT_DIR": "/p"]) == "/p")
    #expect(Env.value("SUPPORT_DIR", in: ["AIRSCP_SUPPORT_DIR": "/a", "PORTER_SUPPORT_DIR": "/p"]) == "/a")
    #expect(Env.value("SUPPORT_DIR", in: ["PORTER_SSH_DIR": "/s"]) == nil)
    #expect(Keychain.isThrowaway(["PORTER_SUPPORT_DIR": "/p"]) && !Keychain.isThrowaway(["PORTER_SSH_DIR": "/s"]))
}

/// The first start after the rename takes over Porter's settings folder (porter.json as airscp.json, the trusted
/// Remote Desktop certificates; not a running Porter's agent socket or Terminal scripts) and its defaults (the sidebar,
/// columns; not window frames), leaving Porter's as they were. Once only: from then on AirSCP's own are used.
@Test func theFirstStartTakesOverPortersSettings() throws {
    let root = try scratch()
    let old = URL(fileURLWithPath: root + "/Porter"), new = URL(fileURLWithPath: root + "/Support/AirSCP")
    var data = AirSCPData()
    data.hosts = [sampleHost()]
    data.settings.showHidden = true
    for folder in ["freerdp/server", "agent", "Terminal"] {
        try FileManager.default.createDirectory(atPath: old.path + "/" + folder, withIntermediateDirectories: true)
    }
    try JSONEncoder().encode(data).write(to: old.appendingPathComponent("porter.json"))
    try "certificate".write(toFile: old.path + "/freerdp/server/win.example_3389.pem", atomically: true, encoding: .utf8)
    try "token".write(toFile: old.path + "/agent/token", atomically: true, encoding: .utf8)
    try "ssh".write(toFile: old.path + "/Terminal/web.command", atomically: true, encoding: .utf8)
    // Porter's defaults and AirSCP's, in memory (never the Mac's own).
    let defaults = try #require(MemoryDefaults(suiteName: nil))
    let frame = "NSWindow Frame Main", columns = "NSTableView Columns v3 Porter.RightPane"
    let sidebar = "NSSplitView Subview Frames Sidebar"
    // Porter saved its window taller than the screen, which opened AirSCP full height (user report, 2026-10-05).
    defaults.domains["com.sa.porter"] = [frame: "338 -966 1113 2050 0 0 1728 1084 ", columns: Data([1, 2, 3]),
                                         "NSWindow Frame GoToSheet": "634 547 460 215 0 0 1728 1084 ",
                                         sidebar: ["0.000000, 0.000000, 218.000000, 2050.000000, NO, NO"]]
    Store.copyFromPorter(old, to: new, defaults: defaults, porterDomain: "com.sa.porter")

    #expect(try JSONDecoder().decode(AirSCPData.self, from: Data(contentsOf: new.appendingPathComponent("airscp.json"))) == data)
    #expect(read(new.path + "/freerdp/server/win.example_3389.pem") == "certificate")
    #expect(names(in: new.path) == ["airscp.json", "freerdp"] && names(in: root + "/Support") == ["AirSCP"])
    // The columns and the sidebar's width come along; window frames don't: AirSCP's windows open at their own sizes.
    #expect(defaults.values[columns] as? Data == Data([1, 2, 3]) && defaults.values[sidebar] != nil)
    #expect(defaults.values.count == 2, "\(defaults.values.keys.sorted())")
    // Porter's own are as they were.
    #expect(names(in: old.path) == ["Terminal", "agent", "freerdp", "porter.json"] && read(old.path + "/agent/token") == "token")

    // Once only: what Porter or AirSCP changed afterwards stays as it is.
    try "{}".write(toFile: old.path + "/porter.json", atomically: true, encoding: .utf8)
    defaults.values[columns] = Data([9])
    Store.copyFromPorter(old, to: new, defaults: defaults, porterDomain: "com.sa.porter")
    #expect(try JSONDecoder().decode(AirSCPData.self, from: Data(contentsOf: new.appendingPathComponent("airscp.json"))) == data)
    #expect(defaults.values[columns] as? Data == Data([9]) && defaults.values[frame] == nil)

    // Nothing of Porter's on this Mac: nothing is made (the first save makes the folder).
    let fresh = URL(fileURLWithPath: root + "/Fresh/AirSCP")
    Store.copyFromPorter(URL(fileURLWithPath: root + "/none"), to: fresh, defaults: defaults, porterDomain: "none")
    #expect(!exists(fresh.path) && !exists(root + "/Fresh"))
}

/// UserDefaults in memory, for `Store.copyFromPorter`: what it reads (other apps' domains) and what it sets.
final class MemoryDefaults: UserDefaults {
    var domains: [String: [String: Any]] = [:], values: [String: Any] = [:]
    override func persistentDomain(forName name: String) -> [String: Any]? { domains[name] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@Test func filesFromTheFirstVersionLoadWithTheNewDefaults() throws {
    // airscp.json as the first version wrote it: no proxies or RDP entries; hosts and settings without the newer keys.
    let old = """
        {"groups": [], "snippets": [],
         "hosts": [{"auth": "keyFile", "defaultRemoteDir": "/srv", "extraOptions": [], "forwardAgent": false,
                    "hostname": "web", "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "keyFile": "/k/id", "label": "Web",
                    "port": 2222, "tunnels": [], "username": "deploy"}],
         "settings": {"confirmDelete": true, "downloadFolder": "/tmp", "preserveTimes": true, "showHidden": false,
                      "terminalApp": "iTerm"}}
        """
    let data = try JSONDecoder().decode(AirSCPData.self, from: Data(old.utf8))
    let host = try #require(data.hosts.first)
    #expect(host.hostname == "web" && host.port == 2222 && host.keyFile == "/k/id" && host.defaultRemoteDir == "/srv")
    #expect(host.proxyID == nil && host.serverAliveInterval == 15 && host.autoReconnect)
    #expect(data.settings.terminalApp == .iTerm && data.settings.preserveTimes)
    #expect(data.settings.appearance == .system && !data.settings.alwaysCalculateFolderSizes && !data.settings.verifyTransfers)
    #expect(data.proxies.isEmpty && data.rdpEntries.isEmpty)

    // What this version writes reads back the same.
    var new = data
    new.proxies = [Proxy(name: "Office", host: "proxy.lan", port: 3128, username: "me")]
    new.hosts[0].proxyID = new.proxies[0].id
    new.hosts[0].serverAliveInterval = 5
    var desktop = RDPEntry(label: "Win", hostname: "win.lan", username: "porter")
    desktop.viaHostID = host.id
    desktop.display = .fixed(width: 1440, height: 900)
    new.rdpEntries = [desktop]
    new.settings.appearance = .dark
    new.settings.verifyTransfers = true
    #expect(try JSONDecoder().decode(AirSCPData.self, from: JSONEncoder().encode(new)) == new)
}
