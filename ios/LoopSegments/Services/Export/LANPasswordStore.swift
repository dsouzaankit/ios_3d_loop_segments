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

    static let minimumLength = 8
    static let maximumLength = 64
    /// No 0/o, 1/l/i: easy to read off the phone and type on a Quest keyboard.
    private static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    /// The password the server checks. Read from the Keychain once, then from memory.
    static var current: String {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if let stored = readKeychain() {
            cached = stored
            return stored
        }
        let fresh = makeRandomPassword()
        writeKeychain(fresh)
        cached = fresh
        return fresh
    }

    /// Saves a password the user chose. Returns an error message when it is not allowed.
    @discardableResult
    static func set(_ password: String) -> String? {
        if let problem = validationProblem(password) { return problem }
        lock.lock()
        defer { lock.unlock() }
        writeKeychain(password)
        cached = password
        return nil
    }

    /// Replaces the password with a new random one and returns it.
    @discardableResult
    static func regenerate() -> String {
        let fresh = makeRandomPassword()
        lock.lock()
        defer { lock.unlock() }
        writeKeychain(fresh)
        cached = fresh
        return fresh
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

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func readKeychain() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8),
              validationProblem(text) == nil
        else { return nil }
        return text
    }

    private static func writeKeychain(_ password: String) {
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = Data(password.utf8)
        // The LAN server runs while the phone is locked (Keep Alive), so allow reads after first unlock.
        // ThisDeviceOnly: not copied into iCloud or device backups.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
