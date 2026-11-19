import CodexBarCore
import CommonCrypto
import Foundation
import LocalAuthentication
import Security

struct KimiDesktopSessionReader {
    /// Cache for the Kimi desktop safeStorage key, backed by our own credential
    /// vault. Reading the original "kimi-desktop Safe Storage" Keychain entry
    /// triggers a macOS authorization prompt on every launch (ad-hoc signing
    /// invalidates its ACL after each build), so after the first authorized
    /// read we cache a copy and only touch Kimi's entry again when the cached
    /// key stops decrypting (key rotation).
    struct SafeStorageKeyCache {
        var read: () -> Data?
        var write: (Data) -> Void
        var clear: () -> Void

        static let live = SafeStorageKeyCache(
            read: { KeychainService.shared.cachedKimiDesktopSafeStorageKey() },
            write: { KeychainService.shared.cacheKimiDesktopSafeStorageKey($0) },
            clear: { KeychainService.shared.clearKimiDesktopSafeStorageKey() })

        static let disabled = SafeStorageKeyCache(
            read: { nil },
            write: { _ in },
            clear: {})
    }

    let home: URL
    let keyCache: SafeStorageKeyCache
    let freshKey: (Bool) throws -> Data
    /// Renews the short-lived access token from the store's own refresh token.
    ///
    /// The desktop client only rewrites its token store while it is running,
    /// so an access token left behind when it last quit is already expired.
    /// Injected so tests can exercise the renewal without network access.
    let renewAccessToken: (@Sendable (String, String) async throws -> KimiDesktopTokenRefresher.Refreshed)?
    /// Holds a renewed token so repeated polls reuse it instead of renewing
    /// again on every cycle.
    let tokenCache: KimiDesktopTokenCache

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        keyCache: SafeStorageKeyCache = .live,
        freshKey: ((Bool) throws -> Data)? = nil,
        renewAccessToken: (@Sendable (String, String) async throws -> KimiDesktopTokenRefresher.Refreshed)? = nil,
        tokenCache: KimiDesktopTokenCache = .shared
    ) {
        self.home = home
        self.keyCache = keyCache
        self.freshKey = freshKey ?? { try Self.password(allowInteraction: $0) }
        self.tokenCache = tokenCache
        self.renewAccessToken = renewAccessToken ?? { refreshToken, origin in
            try await KimiDesktopTokenRefresher()
                .refresh(refreshToken: refreshToken, origin: origin)
        }
    }

    var tokenStoreURL: URL {
        home.appendingPathComponent("Library/Application Support/kimi-desktop/bridge-store/token-store.json")
    }

    /// Presence checks never touch Keychain or launch a browser.
    var isPresent: Bool {
        FileManager.default.fileExists(atPath: tokenStoreURL.path)
            || KimiDesktopAuthToken.load(homeDirectory: home) != nil
    }

    func load(allowInteraction: Bool = false) async throws -> KimiWebSession {
        if FileManager.default.fileExists(atPath: tokenStoreURL.path) {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: tokenStoreURL))
            guard envelope.encryption == "safeStorage.v1",
                  let encrypted = Data(base64Encoded: envelope.data) else {
                throw KimiSessionError.invalidStore
            }
            // Cached key first: no prompt, no access to Kimi's Keychain entry.
            // A wrong key can still pass AES padding, so only a fully decodable
            // session counts as a cache hit.
            if let cached = keyCache.read() {
                if let plaintext = try? Self.decrypt(encrypted, password: cached),
                   let store = try? Self.decodeStoreTokens(plaintext) {
                    if let accessToken = store.tokens.access_token,
                       let session = try? KimiWebSession(
                           token: accessToken, origin: store.origin).validated() {
                        return session
                    }
                    // The stored access token expired while Kimi was closed.
                    // Renew it from the same store's refresh token before
                    // giving up — otherwise every later read fails with 401.
                    return try await Self.renewedSession(
                        store: store, renew: renewAccessToken, cache: tokenCache)
                }
                if !allowInteraction {
                    // Stale cache on a background refresh: stay silent and let
                    // the next interactive load re-authorize instead of writing
                    // the vault (a write would prompt too).
                    throw KimiSessionError.keychain(errSecInteractionNotAllowed)
                }
                // Kimi rotated its safeStorage key (or the store changed); drop
                // the stale copy and fall through to a fresh authorized read.
                keyCache.clear()
            } else if !allowInteraction {
                // Background refreshes must never touch Kimi's Keychain entry:
                // on this macOS the partition check prompts even with
                // interactionNotAllowed, so without a cached key there is no
                // silent path. The Settings "Allow Desktop Access" button
                // performs the one interactive read that seeds the cache.
                throw KimiSessionError.keychain(errSecInteractionNotAllowed)
            }
            let password = try freshKey(allowInteraction)
            keyCache.write(password)
            let plaintext = try Self.decrypt(encrypted, password: password)
            let store = try Self.decodeStoreTokens(plaintext)
            if let accessToken = store.tokens.access_token,
               let session = try? KimiWebSession(
                   token: accessToken, origin: store.origin).validated() {
                return session
            }
            return try await Self.renewedSession(
                store: store, renew: renewAccessToken, cache: tokenCache)
        }
        if let token = KimiDesktopAuthToken.load(homeDirectory: home) {
            return try KimiWebSession(token: token, origin: "https://www.kimi.com").validated()
        }
        throw KimiSessionError.missing
    }

    struct Envelope: Decodable { let encryption: String; let data: String }

    /// The desktop client's token store, including the long-lived refresh
    /// token used to renew an expired access token.
    struct StoreTokens: Decodable {
        struct Tokens: Decodable {
            let access_token: String?
            let refresh_token: String?
        }
        let origin: String
        let tokens: Tokens
    }

    static func decodeStoreTokens(_ data: Data) throws -> StoreTokens {
        try JSONDecoder().decode(StoreTokens.self, from: data)
    }

    static func decodeStore(_ data: Data) throws -> KimiWebSession {
        guard let store = try? decodeStoreTokens(data),
              let token = store.tokens.access_token, !token.isEmpty else {
            throw KimiSessionError.invalidStore
        }
        return KimiWebSession(token: token, origin: store.origin)
    }

    /// Renews the access token stored in the desktop client's token store.
    ///
    /// The store keeps both tokens: a short-lived `access_token` and a
    /// long-lived `refresh_token`. The server does not rotate the refresh
    /// token, so renewing here leaves the desktop client's own stored
    /// credential valid — we never write the store.
    static func renewedSession(
        store: StoreTokens,
        renew: (@Sendable (String, String) async throws -> KimiDesktopTokenRefresher.Refreshed)?,
        cache: KimiDesktopTokenCache
    ) async throws -> KimiWebSession {
        guard let refreshToken = store.tokens.refresh_token,
              !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KimiSessionError.expired
        }
        // A token renewed by an earlier poll is still good for this account.
        // Reusing it keeps each refresh cycle to a single request.
        let accountID = store.tokens.access_token.flatMap {
            KimiDesktopTokenRefresher.accountID(of: $0)
        } ?? KimiDesktopTokenRefresher.accountID(of: refreshToken)
        if let cached = cache.token(
            accountID: accountID,
            origin: store.origin) {
            if let session = try? KimiWebSession(
                token: cached, origin: store.origin).validated() {
                return session
            }
            cache.clear()
        }
        guard let renew else { throw KimiSessionError.expired }
        let refreshed: KimiDesktopTokenRefresher.Refreshed
        do {
            refreshed = try await renew(refreshToken, store.origin)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A rejected renewal means the Desktop sign-in itself is gone.
            // Report it as an expired login so the user is told to sign in
            // again instead of seeing an opaque transport failure.
            throw KimiSessionError.expired
        }
        guard !refreshed.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KimiSessionError.expired
        }
        // Store under the same identity used for the lookup, so a renewed
        // token is only ever reused for the account it was read for.
        cache.store(
            refreshed.accessToken,
            accountID: accountID ?? refreshed.accountID,
            origin: refreshed.origin,
            expiry: refreshed.expiry)
        return try KimiWebSession(
            token: refreshed.accessToken, origin: refreshed.origin).validated()
    }

    private static func password(allowInteraction: Bool) throws -> Data {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "kimi-desktop Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let password = result as? Data else {
            throw KimiSessionError.keychain(status)
        }
        return password
    }

    /// Electron/macOS synchronous safeStorage v10. No files or Keychain entries are modified.
    static func decrypt(_ encrypted: Data, password: Data) throws -> Data {
        guard encrypted.starts(with: Data("v10".utf8)), encrypted.count > 3,
              (encrypted.count - 3).isMultiple(of: kCCBlockSizeAES128) else {
            throw KimiSessionError.invalidStore
        }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let keyLength = key.count
        let derived = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                bytes.bindMemory(to: Int8.self).baseAddress, password.count,
                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, keyLength)
        }
        guard derived == kCCSuccess else { throw KimiSessionError.invalidStore }
        let payload = Data(encrypted.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: payload.count + kCCBlockSizeAES128)
        let capacity = output.count
        var length = 0
        let status = payload.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                key, key.count, iv, bytes.baseAddress, payload.count, &output, capacity, &length)
        }
        guard status == kCCSuccess else { throw KimiSessionError.invalidStore }
        return Data(output.prefix(length))
    }
}
