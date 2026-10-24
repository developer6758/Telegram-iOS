import Foundation
import CryptoKit
import Security

struct CapsuleSession: Codable {
    let accessToken: String
    let refreshToken: String
    let accessExpiresMs: Int64
    let telegramId: String
    enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", accessExpiresMs = "expires_ms", telegramId = "telegram_user_id" }
}

public struct CapsuleSealedMessage: Codable {
    public let operationId: String
    public let capsuleId: String
    public let recipientId: String
    public let carrier: String
    public let nativeRandomId: Int64
}

struct CapsuleOutboxOperation: Codable {
    let operationId: String
    let nativeRandomId: Int64
    let recipientId: String
    let payload: CapsulePayload
    let durationSeconds: Int64
    let layout: CapsuleLayout
    var reservation: CapsuleReserveResponse?
    var encrypted: CapsuleEncryptedPayload?
    var sealed: CapsuleSealedMessage?
    var enqueued: Bool
}

struct CapsuleCachedRelease: Codable {
    let descriptorSHA256: String
    let payload: CapsulePayload
    var locallyOpened: Bool
}

struct CapsuleDeletionIntent: Codable {
    let capsuleId: String
    let forEveryone: Bool
    let operationId: String
    var acknowledged: Bool?

    init(capsuleId: String, forEveryone: Bool, operationId: String, acknowledged: Bool? = nil) {
        self.capsuleId = capsuleId
        self.forEveryone = forEveryone
        self.operationId = operationId
        self.acknowledged = acknowledged
    }
}

struct CapsuleStoreState: Codable {
    var schemaVersion = 1
    var session: CapsuleSession?
    var outbox: [String: CapsuleOutboxOperation] = [:]
    var releases: [String: CapsuleCachedRelease] = [:]
    var deletions: [String: CapsuleDeletionIntent] = [:]
    // Optional for the additive v1 migration: older encrypted stores have no remote tombstones.
    var unavailableRevisions: [String: Int64]?
}

/// An atomic account-local encrypted side store, never an evictable shared app-group cache.
/// The file contains one AES-GCM envelope. Its account/service AAD prevents cross-account moves.
final class CapsuleStore {
    private let lock = NSRecursiveLock()
    private let url: URL
    private let account: String
    private let aad: Data
    private let keychainService: String

    init(accountId: String, service: String, directory: URL) throws {
        account = accountId
        aad = Data("TCAP-LOCAL-v1\0\(service)\0\(accountId)".utf8)
        keychainService = "org.telegram.TimeCapsule.\(service)"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excludedDirectory = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excludedDirectory.setResourceValues(values)
        url = directory.appendingPathComponent("capsules-v1.aesgcm")
        // Validate corruption/missing Keychain material immediately, without resetting existing state.
        if FileManager.default.fileExists(atPath: url.path) { _ = try read() }
    }

    private func wrappingKey(create: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let bytes = result as? Data, bytes.count == 32 { return SymmetricKey(data: bytes) }
        guard status == errSecItemNotFound, create else { throw CapsuleError.unavailable }
        let bytes = try CapsuleCrypto.random(32)
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: bytes]
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem { return try wrappingKey(create: false) }
        guard addStatus == errSecSuccess else { throw CapsuleError.unavailable }
        return SymmetricKey(data: bytes)
    }

    func read() throws -> CapsuleStoreState {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return CapsuleStoreState() }
        let encrypted = try Data(contentsOf: url, options: .mappedIfSafe)
        guard encrypted.count <= 64 * 1024 * 1024 else { throw CapsuleError.unavailable }
        let key = try wrappingKey(create: false)
        var bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key, authenticating: aad)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        let state = try JSONDecoder().decode(CapsuleStoreState.self, from: bytes)
        guard state.schemaVersion == 1 else { throw CapsuleError.unavailable }
        return state
    }

    @discardableResult func update<T>(_ body: (inout CapsuleStoreState) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var state = try read()
        let result = try body(&state)
        var bytes = try JSONEncoder().encode(state)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        // Preserve the last readable snapshot when the side store reaches its documented cap.
        // Never write a file that read() would reject on the next launch.
        guard bytes.count <= 64 * 1024 * 1024 - 28 else { throw CapsuleError.unavailable }
        let key = try wrappingKey(create: !FileManager.default.fileExists(atPath: url.path))
        guard let encrypted = try AES.GCM.seal(bytes, using: key, authenticating: aad).combined else { throw CapsuleError.unavailable }
        #if os(iOS)
        try encrypted.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try encrypted.write(to: url, options: .atomic)
        #endif
        var protectedURL = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
        return result
    }

    func destroy() throws {
        lock.lock(); defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CapsuleError.unavailable }
    }
}
