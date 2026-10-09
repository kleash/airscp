import Foundation

/// WinSCP's sites, from the WinSCP.ini that its Tools ▸ Export/Backup Configuration writes (or that a portable WinSCP
/// keeps beside itself). Each SSH site (SFTP or SCP) becomes a host: its address, port, user, folder, its key (a
/// PuTTY .ppk, by file name), a tunnel as a jump host and an HTTP proxy as a proxy. Stored passwords are never read:
/// AirSCP asks for them when it connects. FTP, WebDAV and S3 sites are left out, with the reason.
public enum WinSCP {
    public struct Site: Equatable {
        /// The site's name without its folder.
        public var name = ""
        /// Its folder in WinSCP's Login dialog ("Work/Web" for a folder in a folder); empty at the top.
        public var folder = ""
        public var hostname = ""
        public var port = 22
        public var username = ""
        public var remoteDirectory = ""
        /// The .ppk's file name (the path is on the Windows PC), empty without one.
        public var keyName = ""
        public var tunnel: Hop?
        public var proxy: Hop?
        /// Why it isn't imported, else nil.
        public var leftOut: String?
    }

    /// A tunnel's jump host or a proxy: where and as whom.
    public struct Hop: Hashable {
        public var host = ""
        public var port = 22
        public var username = ""
        public var keyName = ""
    }

    /// The sites in WinSCP.ini's text, in its order (the default settings and saved workspaces aren't sites).
    public static func sites(in text: String) -> [Site] {
        var sections: [(name: String, values: [String: String])] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if let equals = line.firstIndex(of: "="), !sections.isEmpty, !line.hasPrefix(";") {
                sections[sections.count - 1].values[String(line[..<equals])] = decode(String(line[line.index(after: equals)...]))
            }
        }
        return sections.compactMap { section in
            guard section.name.hasPrefix("Sessions\\") else { return nil }
            let path = decode(String(section.name.dropFirst("Sessions\\".count)))
            let values = section.values
            guard path != "Default Settings", values["IsWorkspace"] != "1" else { return nil }
            var site = Site()
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            site.name = parts.last ?? path
            site.folder = parts.dropLast().joined(separator: "/")
            site.hostname = values["HostName"] ?? ""
            site.port = Int(values["PortNumber"] ?? "") ?? 22
            site.username = values["UserName"] ?? ""
            site.remoteDirectory = values["RemoteDirectory"] ?? ""
            site.keyName = fileName(values["PublicKeyFile"] ?? "")
            if values["Tunnel"] == "1", let host = values["TunnelHostName"], !host.isEmpty {
                site.tunnel = Hop(host: host, port: Int(values["TunnelPortNumber"] ?? "") ?? 22,
                                  username: values["TunnelUserName"] ?? "", keyName: fileName(values["TunnelPublicKeyFile"] ?? ""))
            }
            // ProxyMethod: 0 none, 1 SOCKS4, 2 SOCKS5, 3 HTTP, 4 Telnet, 5 a local command.
            let method = Int(values["ProxyMethod"] ?? "") ?? 0
            if method == 3, let host = values["ProxyHost"], !host.isEmpty {
                site.proxy = Hop(host: host, port: Int(values["ProxyPort"] ?? "") ?? 80, username: values["ProxyUsername"] ?? "")
            }
            // FSProtocol: 0 SCP, 1 SFTP (SCP when it can't), 2 SFTP (the default), 5 FTP, 6 WebDAV, 7 S3.
            let kind = ["5": "an FTP site", "6": "a WebDAV site", "7": "an S3 site"][values["FSProtocol"] ?? ""]
            if let kind {
                site.leftOut = "\(kind): AirSCP connects over SSH (SFTP and SCP) only"
            } else if site.hostname.isEmpty {
                site.leftOut = "it has no host name"
            } else if site.hostname.hasPrefix("-") {
                site.leftOut = "a host name starting with “-” can't be used: ssh would read it as an option"
            } else if (1...2).contains(method) || method >= 4 {
                site.leftOut = "it connects through a \(method <= 2 ? "SOCKS proxy" : "proxy WinSCP runs itself"), "
                    + "which AirSCP can't use: add the host by hand"
            }
            return site
        }
    }

    /// The hosts, groups and proxies the sites make, beside what AirSCP has (`existing`): a site it has (same name and
    /// address) is skipped, so importing again adds only new sites. A folder becomes a group (one of that name is
    /// reused), a tunnel a jump host and a proxy a proxy (one per address, reusing AirSCP's). `key` gives the OpenSSH
    /// key made from a .ppk's file name, nil when there is none.
    public static func data(_ sites: [Site], existing: AirSCPData = AirSCPData(), key: (String) -> String? = { _ in nil })
        -> AirSCPData {
        var data = AirSCPData()
        var groupIDs = Dictionary(existing.groups.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        var jumps = Dictionary(existing.hosts.map { (Hop(host: $0.hostname, port: $0.port ?? 22, username: $0.username), $0.id) },
                               uniquingKeysWith: { first, _ in first })
        var proxies = Dictionary(existing.proxies.map { (Hop(host: $0.host, port: $0.port, username: $0.username), $0.id) },
                                 uniquingKeysWith: { first, _ in first })
        func host(_ label: String, _ hop: Hop) -> SSHHost {
            var host = SSHHost(label: label, hostname: hop.host, port: hop.port == 22 ? nil : hop.port, username: hop.username)
            if let path = key(hop.keyName) {
                host.auth = .keyFile
                host.keyFile = path
            }
            return host
        }
        for site in sites where site.leftOut == nil
            && !existing.hosts.contains(where: { $0.label == site.name && $0.hostname == site.hostname }) {
            var made = host(site.name, Hop(host: site.hostname, port: site.port, username: site.username, keyName: site.keyName))
            made.defaultRemoteDir = site.remoteDirectory
            if !site.folder.isEmpty {
                if groupIDs[site.folder] == nil {
                    let group = HostGroup(name: site.folder)
                    data.groups.append(group)
                    groupIDs[site.folder] = group.id
                }
                made.groupID = groupIDs[site.folder]
            }
            // The proxy is for the first hop: the jump host when there is one.
            var proxyID: UUID?
            if let hop = site.proxy {
                if proxies[hop] == nil {
                    let proxy = Proxy(host: hop.host, port: hop.port, username: hop.username)
                    data.proxies.append(proxy)
                    proxies[hop] = proxy.id
                }
                proxyID = proxies[hop]
            }
            if let tunnel = site.tunnel {
                // One jump host per address, whichever key the site names for it.
                let address = Hop(host: tunnel.host, port: tunnel.port, username: tunnel.username)
                if jumps[address] == nil {
                    var jump = host(tunnel.host, tunnel)
                    jump.groupID = made.groupID
                    jump.proxyID = proxyID
                    data.hosts.append(jump)
                    jumps[address] = jump.id
                }
                made.jumpHostID = jumps[address]
            } else {
                made.proxyID = proxyID
            }
            data.hosts.append(made)
        }
        return data
    }

    /// The sites' PuTTY keys as OpenSSH keys in `folder` (named as the .ppk, without ".ppk"), from the .ppk files in
    /// `beside` (the Windows paths can't be followed). Keys with a passphrase are left for Window ▸ Keys, a key imported
    /// before is used again, and another key of the same name is never replaced. Returns the key path by .ppk name, and
    /// a note for each one that couldn't be used.
    public static func importKeys(of sites: [Site], beside: String, into folder: String) async -> (keys: [String: String], notes: [String]) {
        var keys: [String: String] = [:], notes: [String] = []
        let names = Set(sites.flatMap { [$0.keyName, $0.tunnel?.keyName ?? ""] }).filter { !$0.isEmpty }
        for name in names.sorted() {
            guard let text = try? String(contentsOfFile: (beside as NSString).appendingPathComponent(name), encoding: .utf8),
                  let encrypted = PuTTYKey.isEncrypted(text) else {
                notes.append("\(name) isn't beside the file: copy it there and import again, or choose the key in Edit Host.")
                continue
            }
            guard !encrypted else {
                notes.append("\(name) has a passphrase: import it in Window ▸ Keys, then choose it in Edit Host.")
                continue
            }
            let base = (name as NSString).deletingPathExtension.replacingOccurrences(of: " ", with: "_")
            let path = (folder as NSString).appendingPathComponent(base.isEmpty || base.hasPrefix(".") ? "winscp_key" : base)
            if FileManager.default.fileExists(atPath: path) || FileManager.default.fileExists(atPath: path + ".pub") {
                let line = (try? PuTTYKey.read(text, passphrase: "")).map(PuTTYKey.publicLine) ?? ""
                let existing = (try? String(contentsOfFile: path + ".pub", encoding: .utf8)) ?? ""
                if !line.isEmpty, existing.hasPrefix(line.split(separator: " ").prefix(2).joined(separator: " ")) {
                    keys[name] = path
                } else {
                    notes.append("\(name): another key is named \(RemotePath.name(path)) already; choose the key in Edit Host.")
                }
                continue
            }
            do {
                try await Keys.importPPK(text, passphrase: "", to: path, newPassphrase: "", askpass: [:])
                keys[name] = path
            } catch {
                notes.append("\(name): \((error as? AirSCPError)?.message ?? error.localizedDescription)")
            }
        }
        return (keys, notes)
    }

    /// WinSCP.ini escapes characters in names and values as %XX (a space as %20, "\" as %5C).
    static func decode(_ text: String) -> String { text.removingPercentEncoding ?? text }

    /// The file name of a Windows path ("C:\Users\me\key.ppk" → "key.ppk").
    static func fileName(_ path: String) -> String {
        String(path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? "")
    }
}
