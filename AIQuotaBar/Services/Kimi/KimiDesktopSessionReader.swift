import CodexBarCore
import CommonCrypto
import Foundation
import LocalAuthentication
import Security

struct KimiDesktopSessionReader {
    let home: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    var tokenStoreURL: URL {
        home.appendingPathComponent("Library/Application Support/kimi-desktop/bridge-store/token-store.json")
    }

    /// Presence checks never touch Keychain or launch a browser.
    var isPresent: Bool {
        FileManager.default.fileExists(atPath: tokenStoreURL.path)
            || KimiDesktopAuthToken.load(homeDirectory: home) != nil
    }

    func load(allowInteraction: Bool = false) throws -> KimiWebSession {
        if FileManager.default.fileExists(atPath: tokenStoreURL.path) {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: tokenStoreURL))
            guard envelope.encryption == "safeStorage.v1",
                  let encrypted = Data(base64Encoded: envelope.data) else {
                throw KimiSessionError.invalidStore
            }
            let password = try Self.password(allowInteraction: allowInteraction)
            return try Self.decodeStore(Self.decrypt(encrypted, password: password)).validated()
        }
        if let token = KimiDesktopAuthToken.load(homeDirectory: home) {
            return try KimiWebSession(token: token, origin: "https://www.kimi.com").validated()
        }
        throw KimiSessionError.missing
    }

    struct Envelope: Decodable { let encryption: String; let data: String }

    static func decodeStore(_ data: Data) throws -> KimiWebSession {
        struct Store: Decodable {
            struct Tokens: Decodable { let access_token: String? }
            let origin: String
            let tokens: Tokens
        }
        guard let store = try? JSONDecoder().decode(Store.self, from: data),
              let token = store.tokens.access_token, !token.isEmpty else {
            throw KimiSessionError.invalidStore
        }
        return KimiWebSession(token: token, origin: store.origin)
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
