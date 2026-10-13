import Foundation

/// sftp:// and ssh:// links: AirSCP opens them (a saved host with that address, at the path), and
/// Host ▸ Copy Link makes one for the host and folder shown. A link never holds a password.
public struct HostLink: Equatable {
    public enum Scheme: String { case sftp, ssh }
    public var scheme: Scheme
    public var user: String
    public var host: String
    public var port: Int?
    /// The server path (sftp); "" for none.
    public var path: String

    public init(scheme: Scheme, user: String = "", host: String, port: Int? = nil, path: String = "") {
        self.scheme = scheme
        self.user = user
        self.host = host
        self.port = port
        self.path = path
    }

    /// The link's parts, or nil for another scheme or no host. A password in it is ignored.
    public init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme.flatMap({ Scheme(rawValue: $0.lowercased()) }),
              var host = components.host, !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        self.scheme = scheme
        user = components.user ?? ""
        self.host = host
        port = components.port
        // "~" stands for the home folder, as some clients' links write it ("/~/dir").
        var path = components.path
        if path.hasPrefix("/~") { path = String(path.dropFirst()) }
        self.path = path == "/" && scheme == .ssh ? "" : path
    }

    /// The link for `host` and `path` (sftp with a path, else ssh): user@host:port, IPv6 in brackets, the path escaped.
    public static func string(for host: SSHHost, path: String?) -> String {
        var components = URLComponents()
        components.scheme = path == nil ? "ssh" : "sftp"
        if !host.username.isEmpty { components.user = host.username }
        components.host = host.hostname.contains(":") ? "[\(host.hostname)]" : host.hostname
        components.port = host.port
        components.path = path ?? ""
        return components.string ?? ""
    }

    /// Whether `host` is the one this link names: the same address (any case), port (22 when unsaid) and user when the
    /// link says one.
    public func matches(_ host: SSHHost) -> Bool {
        host.hostname.lowercased() == self.host.lowercased() && (host.port ?? 22) == (port ?? 22)
            && (user.isEmpty || host.username == user)
    }
}
