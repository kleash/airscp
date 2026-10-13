import Foundation

/// Host ▸ Server Info…: the server's key as this Mac trusts it,
/// what the connection negotiated (from the debug log's ssh -v lines, when it is on), the server's software, what
/// AirSCP found it can do, and the free space of a folder.
public struct ServerInfo: Equatable, Sendable {
    /// "ED25519 SHA256:…", one per key known_hosts holds for it; empty when known_hosts has none (checks off).
    public var keys: [String] = []
    public var version: String?
    public var kex: String?
    public var cipher: String?
    public var mac: String?
    public var free: Int64?

    /// The plain text Copy puts on the clipboard (as the sheet shows it).
    public func text(host: String, capabilities: [String]) -> String {
        var lines = ["Server: \(host)"]
        lines += keys.isEmpty ? ["Server key: not in known_hosts"] : keys.map { "Server key: \($0)" }
        lines.append("Software: " + (version ?? "unknown"))
        lines.append("Key exchange: " + (kex ?? "unknown"))
        lines.append("Cipher: " + (cipher ?? "unknown") + (mac.map { ", MAC \($0)" } ?? ""))
        lines.append("Can: " + capabilities.joined(separator: ", "))
        if let free { lines.append("Free space: \(free) bytes") }
        return lines.joined(separator: "\n")
    }

    /// The negotiated algorithms and the server's software from ssh -v lines (the last connection's: the latest lines
    /// win), as the debug log has them for this host.
    public static func negotiated(_ log: String) -> (version: String?, kex: String?, cipher: String?, mac: String?) {
        var version: String?, kex: String?, cipher: String?, mac: String?
        for line in log.split(separator: "\n") {
            if let range = line.range(of: "remote software version ") { version = String(line[range.upperBound...]) }
            if let range = line.range(of: "kex: algorithm: ") { kex = String(line[range.upperBound...]) }
            if let range = line.range(of: "kex: server->client cipher: ") {
                let rest = line[range.upperBound...].split(separator: " ")
                cipher = rest.first.map(String.init)
                if let index = rest.firstIndex(of: "MAC:"), index + 1 < rest.count {
                    mac = rest[index + 1] == "<implicit>" ? "built into the cipher" : String(rest[index + 1])
                }
            }
        }
        return (version, kex, cipher, mac)
    }

    /// `ssh-keygen -l -F`'s fingerprint lines: "ED25519 SHA256:…" each.
    public static func fingerprints(_ output: String) -> [String] {
        output.split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap { line in
            let parts = line.split(separator: " ")
            return parts.count >= 3 ? parts[1] + " " + parts[2] : nil
        }
    }
}

extension Session {
    /// Server Info for the folder `folder`: the key's fingerprints from known_hosts (as ssh finds the host there), the
    /// debug log's lines for the rest when it is on, and the folder's free space.
    public func serverInfo(folder: String) async -> ServerInfo {
        var info = ServerInfo()
        if let resolved = await SSHConfig.resolve(host, jump: jump) {
            let name = resolved.hostKeyAlias ?? (resolved.port == 22 ? resolved.hostname : "[\(resolved.hostname)]:\(resolved.port)")
            for file in resolved.knownHostsFiles where FileManager.default.fileExists(atPath: file) {
                let result = await Runner.run([OpenSSH.sshKeygen, "-l", "-F", name, "-f", file], hostID: host.id)
                info.keys += ServerInfo.fingerprints(result.output)
            }
        }
        if DebugLog.enabled {
            let mine = DebugLog.tail(5000).split(separator: "\n").filter { $0.contains("[\(host.displayName)]") }.joined(separator: "\n")
            (info.version, info.kex, info.cipher, info.mac) = ServerInfo.negotiated(mine)
        }
        info.free = try? await diskFree(folder).available
        return info
    }
}
