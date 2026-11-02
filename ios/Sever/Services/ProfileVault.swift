import Foundation
import CryptoKit

final class ProfileVault {
    private let fileURL: URL
    init() throws {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        fileURL = directory.appendingPathComponent("profiles.sealed")
    }

    private func key(create: Bool) throws -> SymmetricKey {
        if let data = try SecretStore.read(account: "vault-key") { return SymmetricKey(data: data) }
        guard create else { throw SeverError.message("Не найден ключ сохранённых профилей") }
        let key = SymmetricKey(size: .bits256)
        try key.withUnsafeBytes { try SecretStore.write(Data($0), account: "vault-key") }
        return key
    }

    func load() throws -> SavedState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return SavedState() }
        let data = try Data(contentsOf: fileURL)
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(create: false))
        return try JSONDecoder().decode(SavedState.self, from: plaintext)
    }

    func save(_ state: SavedState) throws {
        let plaintext = try JSONEncoder().encode(state)
        guard let ciphertext = try AES.GCM.seal(plaintext, using: key(create: true)).combined else {
            throw SeverError.message("Не удалось зашифровать профили")
        }
        try ciphertext.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var resource = fileURL
        var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try resource.setResourceValues(attributes)
    }
}
