import Foundation
import Security

/// Saved passwords: one login-Keychain item (service com.kleash.airscp) holding a JSON dictionary keyed by host id
/// (RDP entries: their id too; proxies: `Proxy.keychainKey`), so macOS asks for access once per app build instead of
/// once per host. Cached after the first read. When the item can't be read (access denied, a locked keychain), nothing
/// is cached and nothing is written: a save then would replace every other saved password.
/// Until AirSCP has an item of its own, the passwords come from the one of its first versions, called Porter (service
/// com.sa.porter, PLAN.md X), and are saved into AirSCP's item at once. Porter's item stays as it is.
/// A throwaway AirSCP (`memoryOnly`: AIRSCP_SUPPORT_DIR set, as tests, smoke runs and agents' instances do) never
/// touches the login Keychain: its saved passwords stay in memory until it quits.
public enum Keychain {
    static let service = "com.kleash.airscp", porterService = "com.sa.porter"
    private static let account = "passwords"
    private static let lock = NSLock()
    static var cache: [String: String]?
    /// Passwords are kept in memory only, never in the login Keychain: true for an instance with its own settings
    /// folder (`Store.directory` from AIRSCP_SUPPORT_DIR).
    public static var memoryOnly = isThrowaway(ProcessInfo.processInfo.environment)

    /// Whether `environment` makes a throwaway instance (its own settings folder).
    public static func isThrowaway(_ environment: [String: String]) -> Bool {
        !(Env.value("SUPPORT_DIR", in: environment) ?? "").isEmpty
    }

    /// The status and data of the item of a service (`service`, or `porterService`), and writing new data to
    /// AirSCP's. Tests replace them (they never touch the login Keychain).
    static var readItem: (_ service: String) -> (status: OSStatus, data: Data?) = { service in
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }
    static var writeItem: (Data) -> OSStatus = { data in
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "AirSCP saved passwords"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status
    }

    public static func password(for hostID: UUID) -> String? {
        password(forKey: hostID.uuidString)
    }

    /// Saves the password, or removes it when `password` is nil.
    public static func setPassword(_ password: String?, for hostID: UUID) {
        setPassword(password, forKey: hostID.uuidString)
    }

    public static func password(forKey key: String) -> String? {
        lock.locked { all()?[key] }
    }

    /// Saves the password under `key`, or removes it when `password` is nil. Not when the item can't be read.
    public static func setPassword(_ password: String?, forKey key: String) {
        lock.locked {
            guard var passwords = all() else {
                log.error("Keychain: not saved, the saved passwords couldn't be read")
                return
            }
            passwords[key] = password
            cache = passwords
            guard !memoryOnly, let data = try? JSONEncoder().encode(passwords) else { return }
            let status = writeItem(data)
            if status != errSecSuccess { log.error("Keychain write failed: \(status, privacy: .public)") }
        }
    }

    /// The saved passwords (none when there is no item yet), or nil when the item couldn't be read.
    private static func all() -> [String: String]? {
        if let cache { return cache }
        if memoryOnly {
            cache = [:]
            return cache
        }
        var (status, data) = readItem(service)
        if status == errSecItemNotFound {
            (status, data) = readItem(porterService)
            if status == errSecSuccess, let data {
                let saved = writeItem(data)
                if saved != errSecSuccess { log.error("Keychain: Porter's saved passwords not copied: \(saved, privacy: .public)") }
            }
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            log.error("Keychain read failed: \(status, privacy: .public)")
            return nil
        }
        let passwords = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = passwords
        return passwords
    }
}
