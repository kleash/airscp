import AirSCPCore
import AirSCPSSH2
import Foundation
import LocalAuthentication
import Security

/// The app's SSH keys: Keychain items that Face ID (or the passcode) unlocks, never files. A host logs in with one
/// by its name (`auth == .keyFile`, `keyFile` = the name). A throwaway instance (tests: AIRSCP_SUPPORT_DIR) keeps
/// them in memory, as `Keychain` does its passwords.
enum KeyStore {
    struct Key: Identifiable, Hashable {
        let name: String
        /// "ssh-ed25519 AAAA… comment"; nil when AirSCP can't read it from the key (an encrypted or PEM key).
        let publicLine: String?
        var id: String { name }
        var type: String? { publicLine?.split(separator: " ").first.map(String.init) }
        var fingerprint: String? {
            publicLine.flatMap { $0.split(separator: " ").dropFirst().first }.flatMap { Data(base64Encoded: String($0)) }
                .map(KnownHosts.fingerprint)
        }
    }

    private static let service = "com.kleash.airscp.keys"
    private static let lock = NSLock()
    private static var memory: [String: (key: Data, publicLine: String?)] = [:]

    static func all() -> [Key] {
        if Keychain.memoryOnly {
            return lock.withLock { memory.map { Key(name: $0.key, publicLine: $0.value.publicLine) } }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        // Attributes only: listing needs no Face ID.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let items = items as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            (item[kSecAttrAccount as String] as? String).map { name in
                Key(name: name, publicLine: (item[kSecAttrGeneric as String] as? Data).map { String(decoding: $0, as: UTF8.self) })
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Saves a private key (an OpenSSH or PEM file's text) under `name`: with a passcode set, only Face ID or the
    /// passcode unlocks it, and it never leaves this device.
    static func add(_ name: String, privateKey: Data, publicLine: String?) throws {
        guard !all().contains(where: { $0.name == name }) else {
            throw AirSCPError(.other, "There is a key named “\(name)” already. Choose another name.")
        }
        if Keychain.memoryOnly {
            lock.withLock { memory[name] = (privateKey, publicLine) }
            return
        }
        var item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: name, kSecAttrLabel as String: "AirSCP key “\(name)”",
                                   kSecValueData as String: privateKey]
        if let publicLine { item[kSecAttrGeneric as String] = Data(publicLine.utf8) }
        if LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil),
           let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil) {
            item[kSecAttrAccessControl as String] = access
        } else {
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly  // no passcode on this device
        }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw AirSCPError(.other, "AirSCP couldn't save the key (error \(status)).") }
    }

    static func remove(_ name: String) {
        if Keychain.memoryOnly {
            _ = lock.withLock { memory.removeValue(forKey: name) }
            return
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: name]
        SecItemDelete(query as CFDictionary)
    }

    /// The private key a host logs in with (`SSH2Transport`'s `privateKey`): asks for Face ID. nil when there is no
    /// such key; cancelling Face ID cancels the login.
    static func privateKey(for host: SSHHost) throws -> Data? {
        if Keychain.memoryOnly { return lock.withLock { memory[host.keyFile]?.key } }
        let context = LAContext()
        context.localizedReason = "Unlock the key “\(host.keyFile)” to log in to \(host.displayName)"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: host.keyFile, kSecReturnData as String: true,
                                    kSecUseAuthenticationContext as String: context]
        var data: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &data) {
        case errSecSuccess: return data as? Data
        case errSecItemNotFound: return nil
        case errSecUserCanceled, errSecAuthFailed: throw AirSCPError.cancelled
        case let status: throw AirSCPError(.other, "AirSCP couldn't unlock the key “\(host.keyFile)” (error \(status)).")
        }
    }

    /// A key file's text as a key to save: OpenSSH and PEM keys as they are, PuTTY keys (.ppk) converted
    /// (`passphrase` unlocks an encrypted one; nil when not asked yet).
    static func read(_ text: String, passphrase: String?) throws -> (privateKey: Data, publicLine: String?) {
        if let encrypted = PuTTYKey.isEncrypted(text) {
            // shortcut: PuTTY 3 passphrases need Argon2, which only the Mac build has (CRDP); add it to iOS when someone needs it.
            if encrypted && text.hasPrefix("PuTTY-User-Key-File-3") {
                throw AirSCPError(.other, "AirSCP on iPhone and iPad can't read a PuTTY key with a passphrase yet. "
                                  + "In PuTTYgen, save it without a passphrase or as an OpenSSH key, then import that.")
            }
            if encrypted && passphrase == nil { throw NeedsPassphrase() }
            let key = try PuTTYKey.read(text, passphrase: passphrase ?? "")
            return (Data(try PuTTYKey.openSSH(key).utf8), PuTTYKey.publicLine(key))
        }
        guard text.contains("PRIVATE KEY-----") else {
            throw AirSCPError(.other, "This file isn't a private key. Choose the key itself, not its .pub file.")
        }
        return (Data(text.utf8), try? PuTTYKey.publicLine(PuTTYKey.fromOpenSSH(text)))
    }

    struct NeedsPassphrase: Error {}
}
