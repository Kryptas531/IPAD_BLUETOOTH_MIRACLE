import Foundation
import Combine
@preconcurrency import Security

/// SPEC c2ab72d §7.3 G. Injectable persistence keeps tests on the real mutation path.
@MainActor
protocol TVLibraryPersistence {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

@MainActor
private struct TVLibraryKeychain: TVLibraryPersistence {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "BTRemote.tv-library",
         kSecAttrAccount as String: "apps-and-bookmarks-v1",
         kSecUseDataProtectionKeychain as String: kCFBooleanTrue!]
    }
    func read() throws -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw LibraryStorageError.unavailable }
        return data
    }
    func write(_ data: Data) throws {
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw LibraryStorageError.unavailable }
        } else if status != errSecSuccess { throw LibraryStorageError.unavailable }
    }
}

private enum LibraryStorageError: Error { case unavailable, invalid }

@MainActor
final class TVLibraryStore: ObservableObject {
    @Published private(set) var library = TVLibrary()
    @Published private(set) var isReady = false
    @Published private(set) var errorMessage: String?
    private let persistence: any TVLibraryPersistence
    private let maxBytes = 1_048_576

    init(persistence: (any TVLibraryPersistence)? = nil) {
        self.persistence = persistence ?? TVLibraryKeychain()
        reload()
    }

    func reload() {
        do {
            let candidate: TVLibrary
            if let data = try persistence.read() {
                guard data.count <= maxBytes else { throw LibraryStorageError.invalid }
                candidate = try JSONDecoder().decode(TVLibrary.self, from: data).validated()
            } else { candidate = try TVLibrary.initial.validated() }
            library = candidate; isReady = true; errorMessage = nil
        } catch {
            isReady = false
            errorMessage = "Saved TV library could not be read. Unlock the iPad and Retry. Saved data has not been replaced."
        }
    }

    @discardableResult func upsert(_ item: TVLibraryItem) -> Bool { mutate { try $0.upsert(item) } }
    @discardableResult func remove(_ id: UUID) -> Bool { mutate { $0.remove(id) } }
    @discardableResult func toggleFavorite(_ id: UUID) -> Bool { mutate { $0.toggleFavorite(id) } }
    @discardableResult func move(_ id: UUID, by offset: Int) -> Bool { mutate { $0.move(id, by: offset) } }
    @discardableResult func recordLaunch(_ id: UUID) -> Bool { mutate { $0.recordLaunch(id) } }

    private func mutate(_ operation: (inout TVLibrary) throws -> Void) -> Bool {
        guard isReady else { return false }
        do {
            var candidate = library
            try operation(&candidate)
            candidate = try candidate.validated()
            let data = try JSONEncoder().encode(candidate)
            guard data.count <= maxBytes else { throw LibraryStorageError.invalid }
            try persistence.write(data)
            library = candidate; errorMessage = nil
            return true
        } catch {
            errorMessage = "TV library change could not be saved. Check the title and target, unlock the iPad and retry. Existing items are unchanged."
            return false
        }
    }
}
