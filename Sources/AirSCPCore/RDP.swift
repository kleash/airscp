import CRDP
import CoreGraphics
import Foundation

/// A Windows desktop over RDP: FreeRDP (vendored, linked statically) behind the C shim in Sources/CRDP, with its event
/// loop on a thread of its own (PLAN.md M, R and S). One RDPSession per connection attempt. The rest of the app sees
/// only `State`, through `RDPWorkspaceController`.
///
/// Callbacks arrive on the main queue. The input, resize and clipboard methods may be called from any thread; they do
/// nothing unless connected.
public final class RDPSession {
    public enum State: Equatable {
        case idle
        case connecting
        case connected
        /// It ended without being asked to, or couldn't connect: show why, with Reconnect.
        case disconnected(AirSCPError)
    }

    /// Where to connect and as whom.
    public struct Target: Equatable {
        public var host: String
        public var port: Int
        public var username: String
        public var domain: String
        /// Empty: asked for while connecting (`onCredentials`).
        public var password: String
        /// Through an SSH host: the port on 127.0.0.1 of a local forward to `host`:`port` (`Session.startTunnel`).
        /// The server is still named `host`:`port`, for its certificate.
        public var tunnelPort: Int?

        public init(host: String, port: Int, username: String, domain: String = "", password: String,
                    tunnelPort: Int? = nil) {
            self.host = host
            self.port = port
            self.username = username
            self.domain = domain
            self.password = password
            self.tunnelPort = tunnelPort
        }
    }

    /// The desktop and what the session shares with the Mac.
    public struct Options {
        /// The desktop's size in pixels.
        public var width = 1280
        public var height = 800
        /// Windows' scaling in percent (100 to 500), and the device's (100, 140 or 180).
        public var desktopScale = 100
        public var deviceScale = 100
        /// A Windows keyboard layout id (`RDPSession.keyboardLayout()`); 0: FreeRDP's default.
        public var keyboardLayout: UInt32 = 0
        /// Text and files both ways.
        public var clipboard = true
        /// This Mac folder is \\tsclient\AirSCP in Windows.
        public var sharedFolder: String?
        /// Where the certificates trusted with Always are kept (FreeRDP's own store).
        public var configDirectory = Store.directory.appendingPathComponent("freerdp").path
        /// How the server's certificate is checked (PLAN.md U.4); `caFile` for `.companyCA`.
        public var certificateCheck = CertificateCheck.ask
        public var caFile = ""

        public init() {}

        /// The entry's certificate check. With a company certificate authority, FreeRDP gets a folder of the entry's
        /// own: its certs/ holds that authority only (it verifies this server, no other), and a certificate the
        /// authority didn't sign but the user trusts with Always is kept there too.
        public mutating func checkCertificates(like entry: RDPEntry) {
            certificateCheck = entry.certificateCheck
            caFile = (entry.caFile as NSString).expandingTildeInPath
            if entry.certificateCheck == .companyCA {
                configDirectory = Store.directory.appendingPathComponent("freerdp-ca/" + entry.id.uuidString).path
            }
        }
    }

    /// A server certificate that isn't trusted yet, or that changed.
    public struct Certificate: Equatable {
        /// host:port
        public let server: String
        public let subject: String
        public let issuer: String
        /// SHA-256, as hex pairs.
        public let fingerprint: String
        /// The fingerprint trusted before, when the server's certificate changed since.
        public let oldFingerprint: String?
        /// The certificate is made out to another name than the server's.
        public let nameMismatch: Bool
    }

    public enum Trust: Int32 {
        case no = 0
        /// Remembered (FreeRDP's store).
        case always = 1
        case once = 2
    }

    public struct Credentials: Equatable {
        public var username: String
        public var domain: String
        public var password: String

        public init(username: String, domain: String = "", password: String) {
            self.username = username
            self.domain = domain
            self.password = password
        }
    }

    /// The mouse pointer Windows shows: an image with its hot spot (in pixels), the standard arrow, or none.
    public enum Pointer {
        case image(CGImage, hotSpot: CGPoint)
        case arrow
        case hidden
    }

    /// One of the files or folders Windows copied. `path` is relative ("Folder/File.txt").
    public struct RemoteFile: Equatable {
        public let path: String
        public let size: UInt64
        public let isFolder: Bool
    }

    public let target: Target
    public let options: Options
    public private(set) var state = State.idle
    /// Connected after NLA checked the password (else the server checks it at its own logon screen, after connecting:
    /// a password typed with Remember is saved only when this is true).
    public private(set) var passwordVerified = false
    /// A certificate trusted with Always couldn't be saved (its folder can't be written): it was trusted this time only.
    public private(set) var certificateNotSaved = false
    /// How long connecting may go without a word from the server (questions waiting for the user don't count).
    public var connectTimeout: TimeInterval = 60
    /// After every state change, on the main queue.
    public var onStateChange: ((State) -> Void)?
    /// The desktop's size in pixels (when connected, and when Windows changes it).
    public var onResize: ((_ width: Int, _ height: Int) -> Void)?
    /// A part of the desktop changed (in desktop pixels, top-left origin). Coalesced: at most one call per main-queue
    /// turn.
    public var onPaint: ((CGRect) -> Void)?
    public var onPointer: ((Pointer) -> Void)?
    /// A certificate to trust (or not) before connecting goes on. No handler: not trusted.
    public var onCertificate: ((Certificate, @escaping (Trust) -> Void) -> Void)?
    /// The user name and password to log in with (nil: cancel). No handler: cancelled.
    public var onCredentials: ((_ username: String, @escaping (Credentials?) -> Void) -> Void)?
    /// What Windows copied: text (line ends as on the Mac), or files and folders (count and total bytes; 0: none).
    public var onClipboardText: ((String) -> Void)?
    public var onClipboardFiles: ((_ count: Int, _ bytes: UInt64) -> Void)?
    /// Windows accepted the shared folder (true) or refused it (its settings turn drive redirection off).
    public var onSharedFolder: ((Bool) -> Void)?
    /// Windows allows the clipboard: text and files can be copied and pasted both ways.
    public var onClipboardReady: (() -> Void)?

    /// The C session; nil once it ended. Held while it is used, so it isn't freed meanwhile.
    private var handle: OpaquePointer?
    private let handleLock = NSLock()
    private var stopped = false
    private var certificateRejected = false
    private var dirty = CGRect.null
    private var paintScheduled = false
    private let paintLock = NSLock()
    /// Reads of Windows' files run here, and the C session is freed here (after a read in flight returned).
    private let fileQueue = DispatchQueue(label: "com.kleash.airscp.rdp.files")
    /// `cancelFetch` counts up: a fetch started before it stops.
    private var fetchGeneration = 0
    /// The session was up (a transport failure afterwards is a lost connection, not an unreachable server).
    private var wasConnected = false
    /// Connecting: when it gives up (pushed back while a question waits for the user), and whether it did.
    private var deadline = Date.distantFuture
    private var asking = false
    private var timedOut = false
    /// The Mac's clipboard goes to the C session here, in order and off the main thread (a big text takes a while).
    private let clipboardQueue = DispatchQueue(label: "com.kleash.airscp.rdp.clipboard")

    public init(target: Target, options: Options = Options()) {
        self.target = target
        self.options = options
    }

    // MARK: Connecting

    /// Connects: `.connecting`, then `.connected`, or `.disconnected` with the reason.
    public func connect() {
        guard handle == nil, state != .connecting else { return }
        connect(authOnly: false)
    }

    /// Disconnects (a certificate or credential question still waiting is answered "no"); the state becomes `.idle`.
    public func disconnect() {
        stopped = true
        withHandle { rdp_session_stop($0) }
        if handle == nil, state != .idle { setState(.idle) }
    }

    /// Logs in and straight out again without a desktop (FreeRDP AuthenticationOnly): Test Connection and the headless
    /// tests. A certificate not trusted yet is asked about through `onCertificate` (none: not trusted). The password
    /// isn't handed over to the server, so no Windows session starts. Throws why it failed.
    public static func testLogin(_ target: Target, options: Options = Options(),
                                 onCertificate: ((Certificate, @escaping (Trust) -> Void) -> Void)? = nil) async throws {
        let session = RDPSession(target: target, options: options)
        session.onCertificate = onCertificate
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.onStateChange = { state in
                switch state {
                case .idle: continuation.resume()
                case .disconnected(let error): continuation.resume(throwing: error)
                case .connecting, .connected: return
                }
                session.onStateChange = nil
            }
            session.connect(authOnly: true)
        }
    }

    /// The Windows keyboard layout of the Mac's current input source. Call it on the main thread.
    public static func keyboardLayout() -> UInt32 {
        rdp_keyboard_layout()
    }

    /// FreeRDP's log lines into the debug log (PLAN.md AE), with the desktop that connected last (FreeRDP's log is one for
    /// the whole app).
    private static let logLine: rdp_log_handler = { line in
        if let line { DebugLog.write(String(cString: line), host: logLock.locked { logHost }) }
    }
    private static let logLock = NSLock()
    private static var logHost = ""

    private func connect(authOnly: Bool) {
        stopped = false
        certificateRejected = false
        certificateNotSaved = false
        wasConnected = false
        timedOut = false
        asking = false
        deadline = Date().addingTimeInterval(connectTimeout)
        setState(.connecting)
        watchConnecting()
        var config = rdp_config()
        config.port = UInt16(clamping: target.port)
        config.tunnel_port = UInt16(clamping: target.tunnelPort ?? 0)
        config.width = UInt32(clamping: options.width)
        config.height = UInt32(clamping: options.height)
        config.desktop_scale = UInt32(clamping: options.desktopScale)
        config.device_scale = UInt32(clamping: options.deviceScale)
        config.keyboard_layout = options.keyboardLayout
        config.clipboard = options.clipboard
        config.auth_only = authOnly
        config.ignore_certificate = options.certificateCheck == .off
        try? FileManager.default.createDirectory(atPath: options.configDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if options.certificateCheck == .companyCA, let problem = Self.installCompanyCA(options) {
            return setState(.disconnected(problem))
        }
        DebugLog.Secrets.add(target.password)
        if DebugLog.enabled {
            let user = (target.domain.isEmpty ? "" : target.domain + "\\") + target.username
            DebugLog.write("Remote Desktop: connecting to \(target.host):\(target.port)" + (user.isEmpty ? "" : " as \(user)")
                + (target.tunnelPort.map { " through the SSH tunnel at 127.0.0.1:\($0)" } ?? "")
                + (authOnly ? " (Test Connection: logging in and out)" : ""), host: target.host)
            Self.logLock.locked { Self.logHost = target.host }
        }
        rdp_log_to(DebugLog.enabled ? Self.logLine : nil)
        let strings = [target.host, target.username, target.domain, target.password, options.configDirectory,
                       options.sharedFolder ?? ""].map { strdup($0) }
        defer { strings.forEach { free($0) } }
        config.host = UnsafePointer(strings[0])
        config.username = UnsafePointer(strings[1])
        config.domain = UnsafePointer(strings[2])
        config.password = target.password.isEmpty ? nil : UnsafePointer(strings[3])
        config.config_dir = UnsafePointer(strings[4])
        config.shared_folder = UnsafePointer(strings[5])

        // FreeRDP's own clients ignore SIGPIPE (freerdp_handle_signals): a write of FreeRDP's on a connection or event pipe
        // whose other end has gone (a server that resets the connection, a session ending) would otherwise end AirSCP;
        // the write fails instead and FreeRDP handles that. Children keep the default (Runner.spawn and cpty reset it).
        signal(SIGPIPE, SIG_IGN)
        // The C session holds on to this object until it ended (released in `ended`).
        let context = Unmanaged.passRetained(self).toOpaque()
        guard let session = rdp_session_new(&config, rdpEvent, context) else {
            Unmanaged<RDPSession>.fromOpaque(context).release()
            return setState(.disconnected(AirSCPError(.other, "AirSCP couldn't set up the Remote Desktop connection.")))
        }
        handleLock.locked { handle = session }
        if !rdp_session_start(session) {
            handleLock.locked { handle = nil }
            rdp_session_free(session)
            Unmanaged<RDPSession>.fromOpaque(context).release()
            setState(.disconnected(AirSCPError(.other, "AirSCP couldn't start the Remote Desktop connection.")))
        }
    }

    private func setState(_ state: State) {
        if DebugLog.enabled {
            switch state {
            case .idle: DebugLog.write("Remote Desktop: not connected", host: target.host)
            case .connecting: break  // `connect` says where to
            case .connected:
                DebugLog.write("Remote Desktop: connected" + (passwordVerified ? " (the password was checked first: NLA)" : ""),
                               host: target.host)
            case .disconnected(let error):
                DebugLog.write("Remote Desktop: disconnected: \(error.message)" + (error.details.isEmpty ? "" : "\n" + error.details),
                               host: target.host)
            }
        }
        self.state = state
        onStateChange?(state)
    }

    /// A server that takes the connection and then says nothing (or too little) would keep it connecting for ever:
    /// stopped after `connectTimeout`, as a timeout.
    private func watchConnecting() {
        // At the deadline (checking every second instead added up the main thread's delays: 30 s for a 3 s timeout in
        // a busy test process); every second while a question waits for its answer, which moves the deadline.
        let wait = asking ? 1 : max(0.1, deadline.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.state == .connecting, !self.stopped else { return }
            if !self.asking && Date() > self.deadline {
                self.timedOut = true
                self.stopped = true
                self.withHandle { rdp_session_stop($0) }
                return
            }
            self.watchConnecting()
        }
    }

    /// A question went to the user, or was answered (the time to connect starts again then).
    private func asked(_ waiting: Bool) {
        asking = waiting
        if !waiting { deadline = Date().addingTimeInterval(connectTimeout) }
    }

    /// Runs `body` with the C session while it exists.
    @discardableResult
    private func withHandle<T>(_ body: (OpaquePointer) -> T) -> T? {
        handleLock.locked { handle.map(body) }
    }

    // MARK: Events (on FreeRDP's threads)

    fileprivate func received(_ event: rdp_event) {
        switch event.type {
        case RDP_EVENT_CONNECTED:
            let (width, height, verified) = (Int(event.width), Int(event.height), event.code == 1)
            DispatchQueue.main.async { [self] in
                wasConnected = true
                passwordVerified = verified
                setState(.connected)
                onResize?(width, height)
            }
        case RDP_EVENT_DISCONNECTED:
            ended(code: event.code, text: event.text.map { String(cString: $0) } ?? "")
        case RDP_EVENT_RESIZED:
            let (width, height) = (Int(event.width), Int(event.height))
            DispatchQueue.main.async { [self] in onResize?(width, height) }
        case RDP_EVENT_PAINT:
            let rect = CGRect(x: Int(event.x), y: Int(event.y), width: Int(event.width), height: Int(event.height))
            let schedule: Bool = paintLock.locked {
                dirty = dirty.union(rect)
                defer { paintScheduled = true }
                return !paintScheduled
            }
            guard schedule else { return }
            DispatchQueue.main.async { [self] in
                let rect: CGRect = paintLock.locked {
                    defer { dirty = .null; paintScheduled = false }
                    return dirty
                }
                onPaint?(rect)
            }
        case RDP_EVENT_CERTIFICATE:
            // Not from FreeRDP's store, nor signed by the entry's certificate authority (for the name it was asked by).
            let server = String(cString: event.text), subject = String(cString: event.subject)
            let fingerprint = String(cString: event.fingerprint)
            // FreeRDP takes a stored copy it can't read (an empty file: a save that failed) for none, and would ask as
            // for a new server: it is asked as a changed certificate instead.
            let damaged = Self.storedCertificateIsDamaged(server, in: options.configDirectory)
            let certificate = Certificate(
                server: server, subject: subject, issuer: String(cString: event.issuer), fingerprint: fingerprint,
                oldFingerprint: event.old_fingerprint.map { String(cString: $0) }
                    ?? (damaged ? "unknown: the copy AirSCP saved is empty or damaged" : nil),
                nameMismatch: event.code & 0x80 != 0)  // VERIFY_CERT_FLAG_MISMATCH
            DispatchQueue.main.async { [self] in
                // Trust automatically: a server's first certificate is trusted and remembered; a changed one is asked
                // about as always.
                let change = certificate.oldFingerprint == nil ? "new" : "changed"
                DebugLog.write("Remote Desktop: the certificate of \(server) needs trust (\(change), SHA-256 "
                    + "\(fingerprint), made out to \(subject))", host: target.host)
                if options.certificateCheck == .trustNew && certificate.oldFingerprint == nil { return answer(.always) }
                guard let onCertificate else { return answer(.no) }
                asked(true)
                onCertificate(certificate) { [self] trust in
                    asked(false)
                    answer(trust)
                }
            }
        case RDP_EVENT_CREDENTIALS:
            let username = String(cString: event.text)
            DispatchQueue.main.async { [self] in
                guard let onCredentials else {
                    withHandle { rdp_session_answer_credentials($0, nil, nil, nil) }
                    return
                }
                asked(true)
                DebugLog.write("Remote Desktop: asks for the user name and password", host: target.host)
                onCredentials(username) { [self] credentials in
                    DebugLog.Secrets.add(credentials?.password)
                    let user = credentials.map { ($0.domain.isEmpty ? "" : $0.domain + "\\") + $0.username }
                    DebugLog.write("Remote Desktop: " + (user.map { "logging in as " + $0 } ?? "logging in was cancelled"),
                                   host: target.host)
                    asked(false)
                    withHandle { session in
                        guard let credentials else { return rdp_session_answer_credentials(session, nil, nil, nil) }
                        rdp_session_answer_credentials(session, credentials.username, credentials.domain,
                                                       credentials.password)
                    }
                }
            }
        case RDP_EVENT_POINTER:
            let pointer = Self.pointer(event)
            DispatchQueue.main.async { [self] in onPointer?(pointer) }
        case RDP_EVENT_CLIPBOARD_TEXT:
            let text = String(cString: event.text).replacingOccurrences(of: "\r\n", with: "\n")
            DispatchQueue.main.async { [self] in onClipboardText?(text) }
        case RDP_EVENT_CLIPBOARD_FILES:
            let (count, bytes) = (Int(event.code), event.size)
            DispatchQueue.main.async { [self] in onClipboardFiles?(count, bytes) }
        case RDP_EVENT_SHARED_FOLDER:
            let status = event.code
            DispatchQueue.main.async { [self] in
                if status != 0 {
                    DebugLog.write("Remote Desktop: Windows refused the shared folder (status 0x" + String(status, radix: 16, uppercase: true)
                        + "): its settings turn drive redirection off", host: target.host)
                }
                onSharedFolder?(status == 0)
            }
        case RDP_EVENT_CLIPBOARD_READY:
            DispatchQueue.main.async { [self] in onClipboardReady?() }
        default:
            break
        }
    }

    private func answer(_ trust: Trust) {
        var trust = trust
        if trust == .no { certificateRejected = true }
        // FreeRDP fails the whole connection when it can't save a certificate trusted with Always: it is trusted for
        // this connection, and `certificateNotSaved` says why it wasn't remembered.
        if trust == .always && !Self.canSaveCertificates(in: options.configDirectory) {
            certificateNotSaved = true
            trust = .once
        }
        DebugLog.write("Remote Desktop: the certificate is " + ["not trusted", "trusted from now on", "trusted this time"][Int(trust.rawValue)],
                       host: target.host)
        withHandle { rdp_session_answer_certificate($0, trust.rawValue) }
    }

    /// Puts the company certificate authority's certificates where FreeRDP looks for them (`<config>/certs`); why it
    /// couldn't, or nil.
    static func installCompanyCA(_ options: Options) -> AirSCPError? {
        let name = (options.caFile as NSString).abbreviatingWithTildeInPath
        guard !options.caFile.isEmpty else {
            return AirSCPError(.noSuchFile, "No certificate authority file is chosen for this desktop. Edit it and choose "
                + "your company's certificate authority file (PEM or DER), or another way to check its certificate.")
        }
        guard FileManager.default.isReadableFile(atPath: options.caFile) else {
            return AirSCPError(.noSuchFile, "AirSCP can't read the certificate authority file “\(name)”. Check that it is "
                + "still there, or edit the desktop to choose it again.")
        }
        try? FileManager.default.createDirectory(atPath: options.configDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        switch airscp_install_ca(options.caFile, options.configDirectory + "/certs") {
        case ..<0:
            return AirSCPError(.permissionDenied, "AirSCP can't put the certificate authority in its folder "
                + "\((options.configDirectory as NSString).abbreviatingWithTildeInPath)/certs.")
        case 0:
            return AirSCPError(.other, "“\(name)” holds no certificate. Choose your company's certificate authority file "
                + "(PEM or DER, often .pem, .cer or .crt).")
        default:
            return nil
        }
    }

    /// Where FreeRDP keeps the certificate trusted with Always for `server` ("host:port"): `<config>/server/host_port.pem`,
    /// lowercase, ":" as "." and slashes as "_" (its certificate_data.c).
    static func storedCertificatePath(_ server: String, in configDirectory: String) -> String {
        let host = server.range(of: ":", options: .backwards).map { String(server[..<$0.lowerBound]) } ?? server
        let port = server.range(of: ":", options: .backwards).map { String(server[$0.upperBound...]) } ?? "3389"
        let name = (host + "_" + port + ".pem").lowercased().replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        return configDirectory + "/server/" + name
    }

    /// A stored certificate for `server` that isn't one (empty, or without a certificate in it).
    static func storedCertificateIsDamaged(_ server: String, in configDirectory: String) -> Bool {
        let path = storedCertificatePath(server, in: configDirectory)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return !text.contains("BEGIN CERTIFICATE")
    }

    /// Whether FreeRDP can save certificates (its store's folder can be made, and written).
    static func canSaveCertificates(in configDirectory: String) -> Bool {
        let folder = configDirectory + "/server"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return FileManager.default.isWritableFile(atPath: folder)
    }

    /// The session's last event: frees the C session (after a file read in flight), then says why it ended.
    private func ended(code: UInt32, text: String) {
        let session: OpaquePointer? = handleLock.locked {
            defer { handle = nil }
            return handle
        }
        if let session {
            rdp_session_cancel_read(session)
            fileQueue.async {
                rdp_session_free(session)
                DispatchQueue.main.async { Unmanaged.passUnretained(self).release() }
            }
        }
        DispatchQueue.main.async { [self] in
            if timedOut {
                setState(.disconnected(AirSCPError(.timeout, "The server took the connection but didn't go on with it. Check "
                    + "that the port is Remote Desktop's (3389 as a rule).", details: "Nothing for \(Int(connectTimeout)) s")))
            } else if code == 0 || stopped {
                setState(.idle)
            } else {
                setState(.disconnected(Self.error(code: code, text: text, certificateRejected: certificateRejected,
                                                  wasConnected: wasConnected)))
            }
        }
    }

    private static func pointer(_ event: rdp_event) -> Pointer {
        let (width, height) = (Int(event.width), Int(event.height))
        guard width > 0, height > 0, let data = event.data else { return event.code == 1 ? .arrow : .hidden }
        let bytes = Data(bytes: data, count: width * height * 4)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                           | CGImageAlphaInfo.first.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return .arrow }
        return .image(image, hotSpot: CGPoint(x: Int(event.x), y: Int(event.y)))
    }

    static let untrusted = "The server's certificate was not trusted, so AirSCP didn't connect. Connect again and choose "
        + "Trust Once or Always Trust if the fingerprint is the one you expect."

    /// A message for FreeRDP's error `code` (FREERDP_ERROR_*: class << 16 | type), FreeRDP's own text under Details.
    /// `wasConnected`: the session had been up, so a failed connection was lost, not refused.
    static func error(code: UInt32, text: String, certificateRejected: Bool = false, wasConnected: Bool = false) -> AirSCPError {
        let details = "\(text) (FreeRDP error 0x\(String(format: "%08X", code)))"
        func error(_ kind: AirSCPError.Kind, _ message: String) -> AirSCPError {
            AirSCPError(kind, message, details: details)
        }
        let errorClass = code >> 16, type = code & 0xFFFF
        if errorClass == 1 {  // the server's reason (ERRINFO_*)
            switch type {
            case 0x01: return error(.other, "The session was disconnected in Windows (another connection may have taken it over). "
                + "Reconnect to take it back.")
            // Windows 11 sends 0x0C both when the user signs out and when they only disconnect.
            case 0x0B, 0x0C: return error(.other, "The Windows session was ended in Windows (signed out or disconnected).")
            case 0x02: return error(.other, "You were signed out of Windows.")
            case 0x03: return error(.other, "Windows ended the session because it was idle.")
            case 0x04: return error(.timeout, "Windows ended the session because the login took too long.")
            case 0x05: return error(.other, "Another connection to this Windows account took over the session.")
            case 0x07, 0x09: return error(.permissionDenied, "The server refused the connection. The account may not be allowed to use Remote Desktop.")
            default: return error(.other, "The server ended the session.")
            }
        }
        guard errorClass == 2 else { return error(.other, "The Remote Desktop connection failed.") }
        if wasConnected { return error(.disconnected, AirSCPError.disconnected.message) }
        switch type {  // ERRCONNECT_*
        case 0x04, 0x05:
            return error(.unknownHost, "Can't find the server. Check the host name and your network connection.")
        case 0x06, 0x0D:
            return error(.refused, "AirSCP couldn't reach the server. Check the host name and port, that Remote "
                + "Desktop is turned on in Windows, and your network.")
        case 0x08:
            if certificateRejected { return error(.hostKeyRejected, untrusted) }
            return error(.other, "The secure connection (TLS) to the server failed.")
        case 0x09, 0x14, 0x15, 0x1B:
            return error(.authFailed(methods: ""), "The user name or password is incorrect. Try again; a domain account needs "
                + "its domain (the Domain field, or DOMAIN\\user).")
        case 0x0B:
            return certificateRejected ? error(.hostKeyRejected, untrusted) : error(.cancelled, "Cancelled.")
        case 0x0C, 0x1E:
            return error(.other, "AirSCP and the server couldn't agree on how to secure the connection.")
        case 0x0E, 0x0F, 0x13:
            return error(.authFailed(methods: ""), "The password has expired. Change it in Windows first.")
        case 0x0A, 0x12, 0x16, 0x17, 0x18, 0x19, 0x1A:
            return error(.permissionDenied, "This account isn't allowed to log in over Remote Desktop (it may be "
                + "disabled, locked or restricted).")
        case 0x1C, 0x1D:
            return error(.timeout, "The server is still starting or didn't answer in time. Try again in a moment.")
        default:
            return error(.other, "The Remote Desktop connection failed.")
        }
    }

    // MARK: Desktop

    /// The desktop's pixels: rows of 32-bit BGRX pixels (sRGB), `stride` bytes apart, top row first.
    public struct Frame {
        public let pixels: UnsafeRawPointer
        public let width: Int
        public let height: Int
        public let stride: Int
    }

    /// Calls `body` with the frame buffer (nil when there is none). It keeps its size meanwhile; don't keep it.
    public func withFrame<T>(_ body: (Frame?) -> T) -> T {
        handleLock.locked {
            guard let handle else { return body(nil) }
            var width: Int32 = 0, height: Int32 = 0, stride: Int32 = 0
            defer { rdp_session_unlock_frame(handle) }
            guard let pixels = rdp_session_lock_frame(handle, &width, &height, &stride), width > 0, height > 0 else {
                return body(nil)
            }
            return body(Frame(pixels: UnsafeRawPointer(pixels), width: Int(width), height: Int(height),
                              stride: Int(stride)))
        }
    }


    /// Asks Windows for a new desktop size (pixels); it is sent once Windows is ready for it.
    public func resize(width: Int, height: Int, desktopScale: Int, deviceScale: Int) {
        withHandle {
            rdp_session_resize($0, UInt32(clamping: width), UInt32(clamping: height), UInt32(clamping: desktopScale),
                               UInt32(clamping: deviceScale))
        }
    }

    // MARK: Input (desktop pixels)

    /// A Mac key (virtual key code). False when it has no scan code: send its characters with `unicode`.
    @discardableResult
    public func key(_ keyCode: UInt16, down: Bool, isRepeat: Bool = false) -> Bool {
        withHandle { rdp_session_key($0, keyCode, down, isRepeat) } ?? true
    }

    /// An RDP scan code (0x100 set: extended key).
    public func scancode(_ code: UInt16, down: Bool) {
        withHandle { rdp_session_scancode($0, code, down) }
    }

    public func unicode(_ text: String) {
        withHandle { session in
            for unit in text.utf16 {
                rdp_session_unicode(session, unit, true)
                rdp_session_unicode(session, unit, false)
            }
        }
    }

    /// Sends Ctrl+Alt+Del (Windows' security screen).
    public func sendCtrlAltDel() {
        let keys: [UInt16] = [0x1D, 0x38, 0x153]  // left Ctrl, left Alt, Delete (extended)
        keys.forEach { scancode($0, down: true) }
        keys.reversed().forEach { scancode($0, down: false) }
    }

    public func mouseMove(to point: CGPoint) {
        withHandle { rdp_session_mouse_move($0, Int32(point.x), Int32(point.y)) }
    }

    /// button: 0 left, 1 right, 2 middle, 3 and 4 the side buttons.
    public func mouseButton(_ button: Int, down: Bool, at point: CGPoint) {
        withHandle { rdp_session_mouse_button($0, Int32(button), down, Int32(point.x), Int32(point.y)) }
    }

    /// delta: wheel units (120 = one notch); positive scrolls up, or right when horizontal.
    public func wheel(horizontal: Bool, delta: Int, at point: CGPoint) {
        withHandle { rdp_session_mouse_wheel($0, horizontal, Int32(clamping: delta), Int32(point.x), Int32(point.y)) }
    }

    /// The desktop got the keyboard focus.
    public func focus(capsLock: Bool) {
        withHandle { rdp_session_focus($0, capsLock) }
    }

    // MARK: Clipboard

    /// The most text offered to Windows (UTF-8 bytes): pasting 5.6 MB of text froze the Windows session in a test, until
    /// Windows was restarted. Over it, offer nothing and say so.
    public static let textLimit = 1 << 20

    /// The Mac copied text: Windows can paste it (converted off the main thread).
    public func offerText(_ text: String) {
        clipboardQueue.async { [self] in
            let windows = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
            withHandle { rdp_session_clipboard_text($0, windows) }
        }
    }

    /// The Mac copied something Windows can't take (an image): Windows pastes nothing rather than the Mac's last text.
    public func offerNothing() {
        clipboardQueue.async { [self] in withHandle { rdp_session_clipboard_text($0, nil) } }
    }

    /// The Mac copied files and folders: Windows can paste them (Explorer). Folders are listed off the main thread.
    /// `done` gets the number of items left out (their paths are longer than Windows takes), on the main queue.
    public func offerFiles(_ urls: [URL], done: ((Int) -> Void)? = nil) {
        clipboardQueue.async { [self] in
            let all = Self.listing(urls)
            let entries = all.filter { $0.name.utf16.count < 260 }  // MAX_PATH with its terminator
            let names = entries.map { strdup($0.name) }, paths = entries.map { strdup($0.url.path) }
            defer { (names + paths).forEach { free($0) } }
            var files = entries.indices.map { index in
                rdp_local_file(path: paths[index], name: names[index], folder: entries[index].isFolder,
                               size: entries[index].size, modified: entries[index].modified)
            }
            withHandle { rdp_session_clipboard_files($0, &files, Int32(files.count)) }
            let skipped = all.count - entries.count
            DispatchQueue.main.async { done?(skipped) }
        }
    }

    /// A name Windows can store: \\ : * ? " < > | and control characters become "_", and so do a trailing dot or space
    /// (Windows would hide data in a stream, make folders of the parts, or refuse the whole paste); a device name
    /// (CON, NUL, COM1, …, also with an extension) gets "_" after it.
    public static func windowsName(_ name: String) -> String {
        var name = String(name.map { "\\:*?\"<>|".contains($0) || ($0.asciiValue ?? 32) < 32 ? "_" : $0 })
        while let last = name.last, last == "." || last == " " { name = String(name.dropLast()) + "_" }
        if isDeviceName(name) {
            let base = name.prefix { $0 != "." }
            name = base + "_" + name.dropFirst(base.count)
        }
        return name
    }

    /// Windows' reserved device names (CON, PRN, AUX, NUL, COM0–9, LPT0–9), bare or with an extension ("nul.txt"
    /// is NUL too), in any case.
    public static func isDeviceName(_ name: String) -> Bool {
        let base = name.prefix { $0 != "." }.uppercased()
        if ["CON", "PRN", "AUX", "NUL"].contains(base) { return true }
        return base.count == 4 && ["COM", "LPT"].contains(String(base.prefix(3))) && base.last!.isNumber
    }

    /// What Windows sees for `urls`: each item, and everything in the folders (folders before their contents;
    /// symbolic links and .DS_Store left out). Names are relative to the items' folder ("/" between folders),
    /// precomposed (NFC), each part as Windows can store it (`windowsName`). Nothing when there are more than `limit`
    /// items (a copied disk, say).
    static func listing(_ urls: [URL], limit: Int = 100_000)
        -> [(url: URL, name: String, isFolder: Bool, size: UInt64, modified: Int64)] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var entries: [(url: URL, name: String, isFolder: Bool, size: UInt64, modified: Int64)] = []
        func add(_ url: URL, name: String) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return }
            let windows = name.precomposedStringWithCanonicalMapping.split(separator: "/", omittingEmptySubsequences: false)
                .map { windowsName(String($0)) }.joined(separator: "/")
            entries.append((url, windows, values.isDirectory == true, UInt64(values.fileSize ?? 0),
                            Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0)))
        }
        for url in urls.map({ $0.resolvingSymlinksInPath() }) {
            let root = url.lastPathComponent
            add(url, name: root)
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
            else { continue }
            let base = url.standardizedFileURL.path
            for case let item as URL in walker {
                if entries.count > limit { return [] }
                let values = try? item.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values?.isSymbolicLink == true || item.lastPathComponent == ".DS_Store" { continue }
                let path = item.standardizedFileURL.path
                guard path.hasPrefix(base + "/") else { continue }
                add(item, name: root + path.dropFirst(base.count))
            }
        }
        return entries
    }

    /// The files and folders Windows copied (from the last `onClipboardFiles`), with the list's serial number.
    public func remoteFiles() -> (serial: UInt32, files: [RemoteFile]) {
        withHandle { session in
            var serial: UInt32 = 0
            let count = rdp_session_remote_files(session, &serial)
            var buffer = [CChar](repeating: 0, count: 2048)
            let files = (0..<max(count, 0)).compactMap { index -> RemoteFile? in
                var size: UInt64 = 0
                var isFolder = false
                guard rdp_session_remote_file(session, serial, Int32(index), &buffer, buffer.count, &size, &isFolder)
                else { return nil }
                return RemoteFile(path: String(cString: buffer), size: size, isFolder: isFolder)
            }
            return (serial, files)
        } ?? (0, [])
    }

    /// Copies the files Windows copied into `folder` (an item whose name is taken gets "name 2"), reading them over
    /// the clipboard channel. `progress` gets the bytes copied so far, at most 10 times a second; `completion` the
    /// items made in `folder`, or the error. Both on the main queue. Partly copied items are removed on failure.
    public func fetchRemoteFiles(into folder: URL, progress: @escaping (UInt64) -> Void,
                                 completion: @escaping (Result<[URL], AirSCPError>) -> Void) {
        let generation = paintLock.locked { fetchGeneration }
        let cancelled = { [self] in paintLock.locked { fetchGeneration != generation } }
        fileQueue.async { [self] in
            var lastReport = Date.distantPast
            let result = Result { try fetch(into: folder, cancelled: cancelled) { done in
                guard Date().timeIntervalSince(lastReport) >= 0.1 else { return }
                lastReport = Date()
                DispatchQueue.main.async { progress(done) }
            } }.mapError { $0 as? AirSCPError ?? AirSCPError(.other, $0.localizedDescription) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Stops the `fetchRemoteFiles` started so far; they end with `.cancelled`.
    public func cancelFetch() {
        paintLock.locked { fetchGeneration += 1 }
        withHandle { rdp_session_cancel_read($0) }
    }

    /// On `fileQueue`, which also frees the C session: it exists until this returns.
    private func fetch(into folder: URL, cancelled: () -> Bool, progress: (UInt64) -> Void) throws -> [URL] {
        guard let session = handleLock.locked({ handle }) else { throw AirSCPError.disconnected }
        let (serial, files) = remoteFiles()
        guard !files.isEmpty else { throw AirSCPError(.noSuchFile, "Windows' clipboard holds no files any more.") }
        let manager = FileManager.default
        var made: [URL] = [], renamed: [String: String] = [:]
        var done: UInt64 = 0
        // 4 MB a request (one in flight): Windows answers a big range nearly as fast as a small one.
        var buffer = [UInt8](repeating: 0, count: 4 << 20)
        do {
            for (index, file) in files.enumerated() {
                var parts = file.path.split(separator: "/").map(String.init)
                guard let top = parts.first, !parts.contains(".."), !parts.contains(".") else { continue }
                if parts.count == 1 || renamed[top] == nil {
                    let existing = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
                    renamed[top] = Names.unique(top, existing: existing, caseInsensitive: true)
                    made.append(folder.appendingPathComponent(renamed[top]!))
                }
                parts[0] = renamed[top]!
                let target = parts.reduce(folder) { $0.appendingPathComponent($1) }
                if file.isFolder {
                    try manager.createDirectory(at: target, withIntermediateDirectories: true)
                    continue
                }
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard manager.createFile(atPath: target.path, contents: nil),
                      let output = FileHandle(forWritingAtPath: target.path)
                else { throw AirSCPError(.permissionDenied, "AirSCP can't write “\(target.lastPathComponent)” there.") }
                defer { try? output.close() }
                var offset: UInt64 = 0
                var piece = UInt64(buffer.count)
                while offset < file.size {
                    if cancelled() { throw AirSCPError.cancelled }
                    let wanted = UInt32(min(piece, file.size - offset))
                    let got = rdp_session_read_remote_file(session, serial, Int32(index), offset, &buffer, wanted)
                    if cancelled() { throw AirSCPError.cancelled }
                    guard got > 0 else {
                        // The session ended (Disconnect, or the connection was lost): no news to show.
                        if stopped || handleLock.locked({ handle == nil }) { throw AirSCPError.disconnected }
                        // Windows never answered some ranges (of 6 881 to 6 884 bytes, in a test), and answers 4 KB ones:
                        // the rest of the file goes in those.
                        if piece > 4096 {
                            piece = 4096
                            continue
                        }
                        throw AirSCPError(.other, "Copying “\(file.path)” from Windows failed. Copy it again in "
                            + "Windows and try once more.")
                    }
                    try output.write(contentsOf: buffer[0..<Int(got)])
                    offset += UInt64(got)
                    done += UInt64(got)
                    progress(done)
                }
            }
        } catch {
            made.forEach { try? manager.removeItem(at: $0) }
            throw error
        }
        return made
    }

    fileprivate static func received(_ context: UnsafeMutableRawPointer?, _ event: UnsafePointer<rdp_event>?) {
        guard let context, let event else { return }
        Unmanaged<RDPSession>.fromOpaque(context).takeUnretainedValue().received(event.pointee)
    }
}

/// The C shim's event handler (FreeRDP's threads).
private func rdpEvent(_ context: UnsafeMutableRawPointer?, _ event: UnsafePointer<rdp_event>?) {
    RDPSession.received(context, event)
}

extension RDPSession {
    /// Through an SSH host: a local forward from a free port on 127.0.0.1 to `host`:`port` over `session`'s connection
    /// (ssh -O forward, so it goes through the host's proxy and jump host too). Stop it with `session.stopTunnel`.
    public static func forward(through session: Session, to host: String, port: Int) async throws -> Tunnel {
        for _ in 0..<3 {
            guard let local = freePort() else { break }
            let tunnel = Tunnel(kind: .local, listenPort: local, targetHost: host, targetPort: port)
            do {
                try await session.startTunnel(tunnel)
                return tunnel
            } catch let error as AirSCPError where error.kind == .portInUse {
                continue  // taken meanwhile: another one
            }
        }
        throw AirSCPError(.portInUse, "AirSCP couldn't find a free port on this Mac for the tunnel. Close other programs that "
            + "open many connections and try again.")
    }

    /// A TCP port on 127.0.0.1 that nothing listens on (right now).
    static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }
}

extension RDPEntry {
    /// Its password's key in AirSCP's Keychain item (`Keychain.password(forKey:)`).
    public var keychainKey: String { "rdp:" + id.uuidString }
}

extension RDPSession {
    /// The files under `folder` that this process has open for writing: what Windows is copying into a shared folder
    /// (FreeRDP's drive channel writes them in AirSCP). Disconnecting would leave them cut off.
    public static func filesBeingWritten(in folder: String) -> [String] {
        let pid = getpid()
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 16)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        // The real path, as the kernel names open files (NSString's resolving would turn /private/tmp into /tmp).
        guard let real = realpath(folder, nil) else { return [] }
        defer { free(real) }
        let prefix = String(cString: real).hasSuffix("/") ? String(cString: real) : String(cString: real) + "/"
        var paths: [String] = []
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let got = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard got == Int32(MemoryLayout<vnode_fdinfowithpath>.size), info.pfi.fi_openflags & UInt32(FWRITE) != 0 else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if path.hasPrefix(prefix) { paths.append(path) }
        }
        return paths
    }
}
