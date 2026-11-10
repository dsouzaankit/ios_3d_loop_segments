import Foundation
import Security

/// The LAN WebDAV password (audit #4). Each install makes its own on first use and keeps it in
/// the Keychain, so it is never in the repo or the IPA and stays the same across launches and
/// SideStore updates. The Export screen shows it and can set a chosen one or make a new one.
enum LANPasswordStore {
    private static let service = "com.loopsegments.lan.webdav"
    private static let account = "admin"
    private static let lock = NSLock()
    private static var cached: String?
    private static var saved = true

    /// False when `current` is not the password stored in the Keychain (it could not be read or
    /// saved), so it only lasts until the app quits. The Export screen says so (audit A9).
    static var isSaved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return saved
    }

    static let minimumLength = 8
    static let maximumLength = 64
    /// No 0/o, 1/l/i: easy to read off the phone and type on a Quest keyboard.
    private static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    /// What a Keychain read found.
    enum StoredPassword: Equatable {
        case found(String)
        /// No item yet (first launch), or an item that is not a usable password.
        case missing
        /// The Keychain could not be read right now (for example locked before first unlock).
        case unreadable(OSStatus)
    }

    /// What `current` does with a read result.
    enum ReadDecision: Equatable {
        case use(String)
        case createNew
        /// Locked before the first unlock: refuse logins for now and read again on the next request.
        case retryLater
        /// The Keychain cannot be used at all (for example a missing entitlement): use a password
        /// kept in memory for this launch only, and never write it, so a stored one is not replaced.
        case sessionOnly
    }

    /// Audit A8: only a missing password is replaced. A read error must not change it.
    static func decide(_ stored: StoredPassword) -> ReadDecision {
        switch stored {
        case .found(let password): return .use(password)
        case .missing: return .createNew
        case .unreadable(let status):
            // Only the "still locked" error clears up by itself; retrying any other error would
            // refuse every login until the app is relaunched.
            return status == errSecInteractionNotAllowed ? .retryLater : .sessionOnly
        }
    }

    /// The password the server checks. Read from the Keychain once, then from memory.
    static var current: String {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let stored = readKeychain()
        switch decide(stored) {
        case .use(let password):
            cached = password
            saved = true
            return password
        case .createNew:
            let fresh = makeRandomPassword()
            let status = writeKeychain(fresh)
            saved = status == errSecSuccess
            if status != errSecSuccess {
                // Still serve it this session, but it will not survive a relaunch.
                SearchDebugLog.log("LAN password: could not save a new password to the Keychain (OSStatus \(status))")
            }
            cached = fresh
            return fresh
        case .retryLater:
            if case .unreadable(let status) = stored {
                SearchDebugLog.log("LAN password: Keychain unreadable (OSStatus \(status)); refusing logins until it can be read")
            }
            // Not cached: no client can match it, and the next request reads the Keychain again.
            saved = false
            return makeRandomPassword()
        case .sessionOnly:
            if case .unreadable(let status) = stored {
                SearchDebugLog.log("LAN password: Keychain unusable (OSStatus \(status)); using a password for this launch only, not saved")
            }
            let fresh = makeRandomPassword()
            cached = fresh
            saved = false
            return fresh
        }
    }

    /// Saves a password the user chose. Returns an error message when it is not saved.
    @discardableResult
    static func set(_ password: String) -> String? {
        if let problem = validationProblem(password) { return problem }
        lock.lock()
        defer { lock.unlock() }
        let status = writeKeychain(password)
        guard status == errSecSuccess else { return saveFailureMessage(status) }
        cached = password
        saved = true
        return nil
    }

    /// Replaces the password with a new random one. Returns nil (old one kept) when it cannot be saved.
    static func regenerate() -> String? {
        let fresh = makeRandomPassword()
        lock.lock()
        defer { lock.unlock() }
        let status = writeKeychain(fresh)
        guard status == errSecSuccess else {
            SearchDebugLog.log("LAN password: \(saveFailureMessage(status))")
            return nil
        }
        cached = fresh
        saved = true
        return fresh
    }

    static func saveFailureMessage(_ status: OSStatus) -> String {
        "Could not save to the Keychain (OSStatus \(status)); the old password is kept."
    }

    /// Printable ASCII only (Basic auth, rclone and Skybox handle it), no spaces at the ends.
    static func validationProblem(_ password: String) -> String? {
        if password.count < minimumLength { return "Use at least \(minimumLength) characters." }
        if password.count > maximumLength { return "Use at most \(maximumLength) characters." }
        if password != password.trimmingCharacters(in: .whitespaces) { return "No spaces at the start or end." }
        let printable = password.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
        if !printable { return "Use plain letters, digits and ASCII symbols only." }
        return nil
    }

    /// 16 random characters in four groups, e.g. `k7mq-x2pd-9wrt-hn4c` (about 79 bits).
    static func makeRandomPassword() -> String {
        var generator = SystemRandomNumberGenerator()
        let chars = (0..<16).map { _ in alphabet.randomElement(using: &generator)! }
        return stride(from: 0, to: 16, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-")
    }

    /// Maps a Keychain read status and data to what was found.
    static func storedPassword(status: OSStatus, data: Data?) -> StoredPassword {
        switch status {
        case errSecSuccess:
            guard let data, let text = String(data: data, encoding: .utf8), validationProblem(text) == nil else {
                return .missing
            }
            return .found(text)
        case errSecItemNotFound:
            return .missing
        default:
            return .unreadable(status)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func readKeychain() -> StoredPassword {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return storedPassword(status: status, data: item as? Data)
    }

    /// Updates in place, or adds when there is no item, so a failed save never deletes the old one.
    private static func writeKeychain(_ password: String) -> OSStatus {
        let data = Data(password.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = baseQuery
        add[kSecValueData as String] = data
        // The LAN server runs while the phone is locked (Keep Alive), so allow reads after first unlock.
        // ThisDeviceOnly: not copied into iCloud or device backups.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
    }
}
