import Foundation

/// An error with a message for people and the raw tool output under "Details".
public struct AirSCPError: Error, LocalizedError, Equatable {
    public enum Kind: Equatable {
        case refused, unknownHost, timeout, noRoute
        /// The server rejected the credentials; `methods` are the ones it allows ("publickey,password").
        case authFailed(methods: String)
        case tooManyAuthFailures, sftpOnly, hostKeyChanged, hostKeyRejected
        case permissionDenied, noSuchFile, failure, diskFull
        /// The master connection is gone: show the Disconnected banner.
        case disconnected
        /// The server allows no more sessions on this connection (MaxSessions).
        case busy
        case portInUse, cancelled, missingTool, notText, other
    }

    public var kind: Kind
    public var message: String
    public var details: String

    public init(_ kind: Kind, _ message: String, details: String = "") {
        self.kind = kind
        self.message = message
        self.details = details
    }

    public var errorDescription: String? { message }

    static let cancelled = AirSCPError(.cancelled, "Cancelled.")
    static let disconnected = AirSCPError(.disconnected, "The connection to the server was lost.")
}

/// Friendly messages for ssh, scp and sftp error output. The first matching rule wins.
public enum ErrorMapping {
    /// `keyFiles`: the key files the host (and its jump host) log in with, full paths: ssh's note that one of them is
    /// missing explains a failed login (a missing file named elsewhere, e.g. ~/.ssh/config's Host *, doesn't).
    public static func map(_ stderr: String, status: Int32, keyFiles: [String] = []) -> AirSCPError {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        func has(_ needle: String) -> Bool { text.range(of: needle, options: .caseInsensitive) != nil }
        func error(_ kind: AirSCPError.Kind, _ message: String) -> AirSCPError {
            AirSCPError(kind, message, details: text.isEmpty ? "Exit status \(status)" : text)
        }

        // The proxy-connect helper's line (ProxyConnect): "AirSCP proxy: HTTP/1.1 407 …", "AirSCP proxy: can't …".
        if let range = text.range(of: "AirSCP proxy: ") {
            let line = String(text[range.upperBound...].prefix { $0 != "\n" && $0 != "\r" })
            let words = line.split(separator: " ")
            if line.hasPrefix("HTTP/"), words.count > 1 {
                if words[1] == "407" { return error(.authFailed(methods: ""), "The proxy rejected the user name or password.") }
                return error(.refused, "The proxy didn't open the connection (\(words.dropFirst().joined(separator: " "))).")
            }
            if line == "cancelled" { return error(.cancelled, "Cancelled.") }
            let kind: AirSCPError.Kind = line.hasPrefix("can't find") ? .unknownHost
                : line.contains("refused") ? .refused : line.contains("timed out") || line.contains("didn't answer") ? .timeout
                : line.hasPrefix("can't connect") ? .noRoute : .other
            return error(kind, line.prefix(1).uppercased() + line.dropFirst() + ".")
        }
        if has("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return error(.hostKeyChanged, "The server's identity (its host key) has changed since you last connected. "
                + "Someone may be intercepting the connection, or the server was reinstalled. "
                + "Only remove the old key if you know why it changed.")
        }
        if has("Host key verification failed") {
            return error(.hostKeyRejected, "The server's host key was not accepted, so AirSCP didn't connect. Connect again and "
                + "click Trust if the fingerprint is the one you expect.")
        }
        // An option ssh doesn't know, from the host's Other options ("command-line: line 0: Bad configuration option: x").
        if let range = text.range(of: #"Bad configuration option: \S+"#, options: .regularExpression) {
            let name = text[range].dropFirst("Bad configuration option: ".count)
            return error(.other, "“\(name)” isn't an ssh option: check the host's Other ssh options (Advanced).")
        }
        if lostConnection(text) {
            return error(.disconnected, "The connection to the server was lost.")
        }
        if has("session request failed") {
            return error(.busy, "The server allows no more sessions on this connection (MaxSessions). "
                + "Close a Terminal window on this host and try again.")
        }
        // Through a jump host, the far side's own words: "channel 0: open failed: connect failed: Name does not resolve".
        if has("Could not resolve hostname") || has("connect failed: Name does not resolve")
            || has("connect failed: Name or service not known") || has("connect failed: Temporary failure in name resolution") {
            return error(.unknownHost, "Can't find the server. Check the host name and your network connection.")
        }
        if has("Connection refused") {
            return error(.refused, "The server refused the connection. Check the port and that its SSH server is running.")
        }
        if has("timed out") {
            return error(.timeout, "The server didn't answer in time. Check the host name, the port and your network.")
        }
        if has("No route to host") || has("Network is unreachable") || has("Network is down") || has("Host is down")
            || has("Can't assign requested address") {
            return error(.noRoute, "The server can't be reached from this network. Check Wi-Fi or VPN; if it sits behind "
                + "another server, set “Connect through” in its settings.")
        }
        // The login failed. ssh may end with "Too many authentication failures" whatever was tried, so what was tried
        // decides the message: a key file that isn't there, then passwords, then keys.
        let methods = text.range(of: #"Permission denied \(([^)]*)\)"#, options: .regularExpression)
            .map { String(text[$0].dropFirst("Permission denied (".count).dropLast()) }
        // ssh only notes a key file that isn't there ("no such identity: <path>: …"), then goes on without it.
        if let missing = text.range(of: #"no such identity: .*: No such file or directory"#, options: .regularExpression) {
            let path = String(text[missing].dropFirst("no such identity: ".count).dropLast(": No such file or directory".count))
            if keyFiles.contains(path) {
                return error(.authFailed(methods: methods ?? ""),
                             "The key file \(path) doesn't exist (any more). Choose another key in the host's settings.")
            }
        }
        if has("Permission denied, please try again") {
            return error(.authFailed(methods: methods ?? ""), "The server didn't accept the user name or password. Check "
                + "the user name in the host's settings (Host ▸ Edit…), then try the password again.")
        }
        if has("Too many authentication failures") {
            return error(.tooManyAuthFailures, "The server gave up after too many keys were offered. "
                + "Choose the right key file in the host's settings.")
        }
        if let methods {
            return error(.authFailed(methods: methods),
                         "The server didn't accept the login; it allows: \(methods.replacingOccurrences(of: ",", with: ", "))."
                            + (methods.contains("publickey") ? " Choose a key under “Log in with” in the host's settings, or "
                                + "install one with Window ▸ Keys." : ""))
        }
        if has("allows sftp connections only") {
            return error(.sftpOnly, "This account allows file transfers (sftp) only: the Files tab works, but not commands, "
                + "Monitor or Run.")
        }
        // scp's and tar's words for a failure on this Mac: not the server's.
        if has("write local") || has("open local") || has("local lstat") || has("stat local") || has("Write failed") {
            if has("No space left on device") || has("Disk quota exceeded") {
                return error(.diskFull, "There isn't enough space on this Mac for the download.")
            }
            if has("Permission denied") || has("Operation not permitted") || has("Read-only file system") {
                return error(.permissionDenied, "AirSCP may not write or read that file on this Mac.")
            }
        }
        if has("No space left on device") || has("Disk quota exceeded") || (has("write remote") && has("Failure")) {
            return error(.diskFull, "The server couldn't write the file. Its disk may be full.")
        }
        if has("Address already in use") {
            return error(.portInUse, "The port is already in use: another program or tunnel listens on it. Choose another "
                + "port in the tunnel's settings.")
        }
        // ssh doesn't say why: the port may be taken, or (a remote tunnel) the server may not allow forwarding.
        if has("Port forwarding failed") || has("forwarding failed for listen port") {
            return error(.portInUse, "The port couldn't be opened: it may be in use, or the server doesn't allow tunnels "
                + "(AllowTcpForwarding). Choose another port in the tunnel's settings, or ask the server's administrator.")
        }
        if has("dest open") && has("Permission denied") {
            return error(.permissionDenied, "You don't have permission to write in that folder on the server. Choose another "
                + "folder, or ask the server's administrator.")
        }
        if has("Permission denied") || has("Operation not permitted") {
            return error(.permissionDenied, "The server didn't allow it: your account may not read or change this item. Check "
                + "its owner and permissions (Get Info), or ask the server's administrator.")
        }
        // scp's and sftp's words for a pipe, a socket or a device: there is nothing to copy.
        if has("not a regular file") {
            return error(.other, "It isn't a file or a folder (a pipe, a socket or a device): it can't be copied.")
        }
        // unzip's words for a file that isn't a zip archive (or a damaged one): not a missing file.
        if has("End-of-central-directory signature not found") || has("cannot find zipfile directory") {
            return error(.other, "It isn't a zip archive, or it is damaged.")
        }
        // sftp says only "No such file" for a folder it can't go into ("realpath /a/b: No such file").
        if has("No such file") || has("\" not found") || has(": not found") {
            return error(.noSuchFile, "The file or folder doesn't exist (any more). Refresh the list (⌘R) to see what is "
                + "there now.")
        }
        if has(": Failure") || text.hasSuffix("Failure") {
            return error(.failure, "The server refused without saying why (a read-only disk, a folder that isn't empty, "
                + "or a name already in use, for example). Details shows the server's own words.")
        }
        // ssh's notes are no reason (they come first through a jump host).
        let firstLine = text.split(separator: "\n").first { line in
            !line.hasPrefix("Warning: Permanently added") && !line.hasPrefix("Pseudo-terminal will not be allocated")
        }.map(String.init)
        return error(.other, firstLine ?? "The command failed (exit status \(status)).")
    }

    /// `map`, for a command that ran on this Mac (the tar unpacking a download): a full disk or a refusal is this Mac's.
    static func mapLocal(_ stderr: String, status: Int32) -> AirSCPError {
        let error = map(stderr, status: status)
        switch error.kind {
        case .diskFull: return AirSCPError(.diskFull, "There isn't enough space on this Mac for the download.", details: error.details)
        case .permissionDenied: return AirSCPError(.permissionDenied, "AirSCP may not write there on this Mac.", details: error.details)
        default: return error
        }
    }

    /// ssh's own words for a connection that ended (only at the start of a line: a file name in an error message must
    /// not read as one).
    static func lostConnection(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            line.hasPrefix("Control socket connect(") || line.hasPrefix("client_loop:")
                || (line.hasPrefix("mux_client_") && line.contains("Broken pipe")) || line.hasPrefix("packet_write_wait:") || line.hasPrefix("Connection closed by ")
                || line.hasPrefix("Connection reset by ") || line.hasPrefix("ssh_dispatch_run_fatal:")
                || line.hasPrefix("Read from remote host ")
                || (line.hasPrefix("Connection to ") && line.contains(" closed by remote host"))
        }
    }

    /// The master is gone: what ssh says when the control socket doesn't answer.
    static func masterGone(_ text: String) -> Bool {
        text.split(separator: "\n").contains { $0.hasPrefix("Control socket connect(") }
    }

    /// After "host key changed": the name ssh looked the server up by in known_hosts ("[host]:port", the host, or a
    /// HostKeyAlias) and the file holding the old key, from ssh's own words ("… host key for [h]:2222 has changed …",
    /// "Offending ED25519 key in <file>:<line>"). Through a jump host, it may be the jump host's key that changed.
    public static func changedHostKey(in stderr: String) -> (name: String, file: String?)? {
        guard let found = stderr.range(of: #"host key for \S+ has changed"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let name = String(stderr[found].dropFirst("host key for ".count).dropLast(" has changed".count))
        let file = stderr.range(of: #"Offending \S+ key in [^\r\n]+:[0-9]+"#, options: .regularExpression).map { range in
            let line = stderr[range]
            return String(line[line.range(of: " key in ")!.upperBound..<line.lastIndex(of: ":")!])
        }
        return (name, file)
    }
}
