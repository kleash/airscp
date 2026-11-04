// Phase 0 spike (PLAN-2.0): can libssh2 do what AirSCP needs, against the Docker lab?
// Runs on the Mac (macos-arm64 slice) and in the iOS Simulator (`xcrun simctl spawn`); ios/Spike/run.sh builds both.
// Throwaway: the real transport comes in Phase 1 (`SSH2Session`). Prints PASS/FAIL lines; exits with the failure count.
import CSSH2
import CommonCrypto
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: ssh2spike <lab key file> <expected SHA256 fingerprints, comma separated>"); exit(2) }
let keyPEM = try! String(contentsOfFile: args[1], encoding: .utf8)
let knownFingerprints = Set(args[2].split(separator: ",").map(String.init))
var failures = 0

func check(_ name: String, _ body: () throws -> String) {
    do { print("PASS \(name): \(try body())") } catch { failures += 1; print("FAIL \(name): \(error)") }
}
struct Failure: Error, CustomStringConvertible { let description: String }

// MARK: - Plumbing

func tcpConnect(_ host: String, _ port: Int) throws -> Int32 {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                         ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { throw Failure(description: "resolve \(host)") }
    defer { freeaddrinfo(res) }
    let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
    guard connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else { close(fd); throw Failure(description: "connect \(host):\(port)") }
    return fd
}

final class SSH {
    let session: OpaquePointer
    let fd: Int32
    init(fd: Int32) throws {
        self.fd = fd
        session = libssh2_session_init_ex(nil, nil, nil, nil)
        libssh2_session_set_blocking(session, 1)
        try ok(libssh2_session_handshake(session, libssh2_socket_t(fd)), "handshake")
    }
    deinit {
        libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "bye", "")
        libssh2_session_free(session)
        close(fd)
    }
    func error() -> String {
        var msg: UnsafeMutablePointer<CChar>?
        var len: Int32 = 0
        libssh2_session_last_error(session, &msg, &len, 0)
        return msg.map { String(cString: $0) } ?? "?"
    }
    func ok(_ rc: Int32, _ what: String) throws {
        if rc != 0 { throw Failure(description: "\(what) (\(rc)): \(error())") }
    }
    var fingerprint: String {
        let hash = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256)!
        let data = Data(bytes: hash, count: 32)
        return "SHA256:" + data.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    var hostKeyType: String {
        var len = 0, type: Int32 = 0
        _ = libssh2_session_hostkey(session, &len, &type)
        return ["?", "rsa", "dss", "ecdsa-256", "ecdsa-384", "ecdsa-521", "ed25519"][Int(min(max(type, 0), 6))]
    }
    func password(_ user: String, _ pass: String) throws {
        try ok(libssh2_userauth_password_ex(session, user, UInt32(user.utf8.count), pass, UInt32(pass.utf8.count), nil), "password")
    }
    func keyboardInteractive(_ user: String, answer: String) throws {
        kbdAnswer = answer
        try ok(libssh2_userauth_keyboard_interactive_ex(session, user, UInt32(user.utf8.count), kbdCallback), "keyboard-interactive")
    }
    func key(_ user: String) throws {
        try ok(libssh2_userauth_publickey_frommemory(session, user, user.utf8.count, nil, 0, keyPEM, keyPEM.utf8.count, nil), "publickey")
    }
    func authMethods(_ user: String) -> String {
        libssh2_userauth_list(session, user, UInt32(user.utf8.count)).map { String(cString: $0) } ?? ""
    }
    func channel() throws -> OpaquePointer {
        guard let ch = libssh2_channel_open_ex(session, "session", 7, 2 * 1024 * 1024, 32768, nil, 0) else { throw Failure(description: "channel: \(error())") }
        return ch
    }
    func exec(_ command: String) throws -> (out: String, status: Int32) {
        let ch = try channel()
        defer { libssh2_channel_free(ch) }
        try ok(libssh2_channel_process_startup(ch, "exec", 4, command, UInt32(command.utf8.count)), "exec")
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 32768)
        while true {
            let n = libssh2_channel_read_ex(ch, 0, &buf, buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        libssh2_channel_close(ch)
        libssh2_channel_wait_closed(ch)
        return (String(decoding: out, as: UTF8.self), libssh2_channel_get_exit_status(ch))
    }
}

// The lab's PAM prompts once for the password (target) or for the code (twofactor).
var kbdAnswer = ""
let kbdCallback: @convention(c) (UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, Int32, Int32,
                                 UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?, UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
                                 UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Void = { _, _, _, _, count, _, responses, _ in
    for i in 0..<Int(count) {
        responses![i].text = strdup(kbdAnswer)
        responses![i].length = UInt32(kbdAnswer.utf8.count)
    }
}

func totp(_ base32: String) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    var bits = 0, value = 0
    var key = [UInt8]()
    for c in base32 { value = value << 5 | alphabet.firstIndex(of: c)!; bits += 5
        if bits >= 8 { key.append(UInt8((value >> (bits - 8)) & 0xff)); bits -= 8 } }
    var counter = UInt64(Date().timeIntervalSince1970 / 30).bigEndian
    var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), key, key.count, &counter, 8, &mac)
    let o = Int(mac[19] & 0x0f)
    let code = (UInt32(mac[o] & 0x7f) << 24 | UInt32(mac[o + 1]) << 16 | UInt32(mac[o + 2]) << 8 | UInt32(mac[o + 3])) % 1_000_000
    return String(format: "%06d", code)
}

// MARK: - Checks

libssh2_init(0)
print("libssh2 \(String(cString: libssh2_version(0)!))")

var target: SSH!
check("handshake + host key check (target)") {
    target = try SSH(fd: try tcpConnect("127.0.0.1", 42201))
    guard knownFingerprints.contains(target.fingerprint) else { throw Failure(description: "unknown key \(target.fingerprint)") }
    return "\(target.hostKeyType) \(target.fingerprint)"
}
check("keyboard-interactive password via PAM (target dev)") {
    let methods = target.authMethods("dev")
    try target.keyboardInteractive("dev", answer: "porter-dev")
    return "offered: \(methods)"
}
check("exec + exit status") {
    let r = try target.exec("uname -sm; echo out; echo err >&2; exit 3")
    guard r.out.contains("Linux"), r.status == 3 else { throw Failure(description: "got \(r)") }
    return r.out.split(separator: "\n").first.map(String.init) ?? ""
}
check("sftp: list a folder and download a file, SHA-256 matches the server's") {
    guard let sftp = libssh2_sftp_init(target.session) else { throw Failure(description: "sftp init: \(target.error())") }
    defer { libssh2_sftp_shutdown(sftp) }
    guard let dir = libssh2_sftp_open_ex(sftp, "/etc", 4, 0, 0, Int32(LIBSSH2_SFTP_OPENDIR)) else { throw Failure(description: "opendir") }
    var names = 0
    var name = [CChar](repeating: 0, count: 512)
    var attrs = LIBSSH2_SFTP_ATTRIBUTES()
    while libssh2_sftp_readdir_ex(dir, &name, name.count, nil, 0, &attrs) > 0 { names += 1 }
    libssh2_sftp_close_handle(dir)
    let path = "/etc/services"
    guard let file = libssh2_sftp_open_ex(sftp, path, UInt32(path.utf8.count), UInt(LIBSSH2_FXF_READ), 0, Int32(LIBSSH2_SFTP_OPENFILE)) else { throw Failure(description: "open \(path)") }
    var data = Data()
    var buf = [CChar](repeating: 0, count: 65536)
    while true { let n = libssh2_sftp_read(file, &buf, buf.count); if n <= 0 { break }; buf.withUnsafeBytes { data.append(contentsOf: $0.prefix(n)) } }
    libssh2_sftp_close_handle(file)
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
    let local = digest.map { String(format: "%02x", $0) }.joined()
    let remote = try target.exec("sha256sum \(path)").out.split(separator: "\n").first { $0.hasSuffix(path) }?.prefix(64) ?? ""
    guard local == remote else { throw Failure(description: "sha mismatch \(local) vs \(remote)") }
    return "/etc has \(names) entries; \(path) \(data.count) bytes, sha256 matches"
}
check("pty + top: full-screen draw, keys, quit, shell exit status") {
    let ch = try target.channel()
    defer { libssh2_channel_free(ch) }
    try target.ok(libssh2_channel_request_pty_ex(ch, "xterm-256color", 14, nil, 0, 80, 24, 0, 0), "pty")
    try target.ok(libssh2_channel_process_startup(ch, "shell", 5, nil, 0), "shell")
    libssh2_session_set_blocking(target.session, 0)
    defer { libssh2_session_set_blocking(target.session, 1) }
    var screen = ""
    func pump(until marker: String, _ seconds: Double) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        var buf = [CChar](repeating: 0, count: 16384)
        while Date() < end {
            let n = libssh2_channel_read_ex(ch, 0, &buf, buf.count)
            if n > 0 { screen += String(decoding: buf.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            if screen.contains(marker) { return true }
            if libssh2_channel_eof(ch) == 1 { return screen.contains(marker) }
            if n == Int(LIBSSH2_ERROR_EAGAIN) || n == 0 { usleep(20_000) }
        }
        return false
    }
    func send(_ s: String) { var rest = Array(s.utf8)
        while !rest.isEmpty { let n = libssh2_channel_write_ex(ch, 0, rest, rest.count); if n > 0 { rest.removeFirst(n) } else { usleep(10_000) } } }
    send("top\r")
    guard pump(until: "Tasks:", 10) else { throw Failure(description: "top never drew its screen; got \(screen.debugDescription.prefix(600))") }
    send("q")
    guard pump(until: "\u{1b}[?25h", 10) else { throw Failure(description: "top did not quit") }
    send("exit 7\r")
    _ = pump(until: "\u{0}never", 5)
    libssh2_session_set_blocking(target.session, 1)
    libssh2_channel_wait_closed(ch)
    let status = libssh2_channel_get_exit_status(ch)
    guard status == 7 else { throw Failure(description: "shell exit status \(status)") }
    return "\(screen.utf8.count) bytes of terminal output, exit 7"
}
check("key login with the lab key (minimal, ed25519 in OpenSSH format)") {
    let s = try SSH(fd: try tcpConnect("127.0.0.1", 42202))
    try s.key("dev")
    return try s.exec("cat /etc/alpine-release").out.trimmingCharacters(in: .whitespacesAndNewlines)
}
check("password method (minimal, no PAM)") {
    let s = try SSH(fd: try tcpConnect("127.0.0.1", 42202))
    try s.password("dev", "porter-min")
    return "ok"
}
check("wrong password is refused, plain error") {
    let s = try SSH(fd: try tcpConnect("127.0.0.1", 42202))
    do { try s.password("dev", "nope"); throw Failure(description: "accepted a wrong password") } catch let e as Failure where e.description.hasPrefix("password") { return e.description }
}
check("key, then a verification code (twofactor)") {
    let s = try SSH(fd: try tcpConnect("127.0.0.1", 42204))
    // The key is a partial success: libssh2 reports an error but the server now wants the code.
    let rc = libssh2_userauth_publickey_frommemory(s.session, "dev", 3, nil, 0, keyPEM, keyPEM.utf8.count, nil)
    let next = s.authMethods("dev")
    guard next.contains("keyboard-interactive") else { try s.ok(rc, "key"); throw Failure(description: "no code asked; methods \(next)") }
    try s.keyboardInteractive("dev", answer: totp("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"))
    guard libssh2_userauth_authenticated(s.session) == 1 else { throw Failure(description: "not authenticated") }
    return try s.exec("whoami").out.trimmingCharacters(in: .whitespacesAndNewlines)
}
check("sftp-only chroot account (target sftponly)") {
    let s = try SSH(fd: try tcpConnect("127.0.0.1", 42201))
    try s.keyboardInteractive("sftponly", answer: "porter-sftp")
    guard let sftp = libssh2_sftp_init(s.session) else { throw Failure(description: "sftp init: \(s.error())") }
    defer { libssh2_sftp_shutdown(sftp) }
    guard let dir = libssh2_sftp_open_ex(sftp, "/upload", 7, 0, 0, Int32(LIBSSH2_SFTP_OPENDIR)) else { throw Failure(description: "opendir /upload") }
    var names: [String] = []
    var name = [CChar](repeating: 0, count: 512)
    var attrs = LIBSSH2_SFTP_ATTRIBUTES()
    while libssh2_sftp_readdir_ex(dir, &name, name.count, nil, 0, &attrs) > 0 { names.append(String(cString: name)) }
    libssh2_sftp_close_handle(dir)
    guard names.contains("other-disk") else { throw Failure(description: "got \(names)") }
    return names.sorted().joined(separator: " ")
}
check("jump host: bastion → target over a direct-tcpip channel") {
    let bastion = try SSH(fd: try tcpConnect("127.0.0.1", 42203))
    try bastion.password("jump", "porter-jump")
    guard let tunnel = libssh2_channel_direct_tcpip_ex(bastion.session, "target", 22, "127.0.0.1", 0) else { throw Failure(description: "direct-tcpip: \(bastion.error())") }
    // libssh2 needs a socket: one end of a socketpair goes to the inner session, a thread pumps the other end.
    var pair: [Int32] = [0, 0]
    socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
    let outer = pair[1]
    libssh2_session_set_blocking(bastion.session, 0)
    fcntl(outer, F_SETFL, fcntl(outer, F_GETFL) | O_NONBLOCK)
    var running = true
    let pump = Thread {
        var buf = [UInt8](repeating: 0, count: 32768)
        var pending = [UInt8]()
        while running {
            var idle = true
            if pending.isEmpty { let n = read(outer, &buf, buf.count); if n > 0 { pending = Array(buf.prefix(n)); idle = false } else if n == 0 { break } }
            if !pending.isEmpty { let n = libssh2_channel_write_ex(tunnel, 0, pending, pending.count); if n > 0 { pending.removeFirst(n); idle = false } else if n != Int(LIBSSH2_ERROR_EAGAIN) { FileHandle.standardError.write("pump: write \(n)\n".data(using: .utf8)!) } }
            let m = libssh2_channel_read_ex(tunnel, 0, &buf, buf.count)
            if m > 0 { var off = 0; while off < m { let w = buf.withUnsafeBytes { write(outer, $0.baseAddress! + off, m - off) }; if w > 0 { off += w } else { usleep(1000) } }; idle = false }
            if libssh2_channel_eof(tunnel) == 1 { FileHandle.standardError.write("pump: tunnel eof\n".data(using: .utf8)!); break }
            if m < 0 && m != Int(LIBSSH2_ERROR_EAGAIN) { FileHandle.standardError.write("pump: read \(m) \(bastion.error())\n".data(using: .utf8)!); break }
            if idle { usleep(2000) }
        }
        close(outer)
    }
    pump.start()
    defer { running = false; usleep(50_000); libssh2_channel_free(tunnel) }
    let inner = try SSH(fd: pair[0])
    guard knownFingerprints.contains(inner.fingerprint) else { throw Failure(description: "target key via bastion \(inner.fingerprint)") }
    try inner.key("dev")
    let host = try inner.exec("hostname").out.trimmingCharacters(in: .whitespacesAndNewlines)
    return "reached \(host.split(separator: "\n").last ?? ""), same host key as direct"
}

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(Int32(failures))
