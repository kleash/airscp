import CryptoKit
import Foundation

/// The servers the app trusts: the keys in its OpenSSH-format known_hosts (`SSH2Transport`'s), for Settings to show
/// and forget.
public enum KnownHosts {
    public struct Entry: Hashable, Identifiable {
        /// The line in the file; also what `forget` removes.
        public let line: String
        /// "host" or "[host]:port", as ssh writes it (a hashed name shows as "|1|…").
        public let host: String
        /// "ssh-ed25519", "ecdsa-sha2-nistp256", "ssh-rsa"…
        public let type: String
        /// "SHA256:…", as ssh-keygen -l shows it.
        public let fingerprint: String
        public var id: String { line }
    }

    public static func entries(_ path: String) -> [Entry] {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            var fields = line.split(separator: " ")
            if fields.first?.hasPrefix("@") == true { fields.removeFirst() }  // @cert-authority, @revoked
            guard !line.hasPrefix("#"), fields.count >= 3, let key = Data(base64Encoded: String(fields[2])) else { return nil }
            return Entry(line: String(line), host: String(fields[0]), type: String(fields[1]), fingerprint: fingerprint(key))
        }
    }

    /// A public key's (wire format) fingerprint as ssh-keygen -l shows it: "SHA256:…".
    public static func fingerprint(_ key: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: key)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Removes the entry's line: the next connection to that server asks about its key again.
    public static func forget(_ entry: Entry, in path: String) throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { $0 != entry.line }
        try kept.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
