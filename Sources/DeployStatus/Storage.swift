import DeployCore
import Foundation
import Security

enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.deploystatus.github",
        kSecAttrAccount as String: "device-session"
    ]
    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw ServiceError.message(SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)")
        }
    }

    static func read() throws -> Credential? {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw ServiceError.message("Unreadable Keychain item.") }
        return try JSONDecoder().decode(Credential.self, from: data)
    }

    static func save(_ credential: Credential) throws {
        let data = try JSONEncoder().encode(credential)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}

struct StateFile: Codable {
    var login: String?
    var lastRepository: String?
    var watches: [Watch] = []
    var readings: [UUID: Reading] = [:]

    func preferredRepository(in repositories: [String]) -> String {
        if let previous = lastRepository ?? watches.last?.repository,
           let match = repositories.first(where: { $0.caseInsensitiveCompare(previous) == .orderedSame }) {
            return match
        }
        return repositories.first ?? ""
    }

    mutating func setFilter(_ filter: WorkflowFilter?, for id: UUID) -> Bool {
        guard let index = watches.firstIndex(where: { $0.id == id }), watches[index].workflowID != nil,
              watches[index].runFilter != filter else { return false }
        watches[index].runFilter = filter
        readings.removeValue(forKey: id)
        return true
    }

    mutating func rename(_ id: UUID, to displayName: String) -> Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = watches.firstIndex(where: { $0.id == id }),
              watches[index].service != name else { return false }
        watches[index].service = name
        return true
    }

    mutating func add(_ candidates: [Watch]) -> Bool {
        var added = false
        for watch in candidates {
            let exists = watches.contains {
                $0.repository.caseInsensitiveCompare(watch.repository) == .orderedSame &&
                $0.workflowID == watch.workflowID && (watch.workflowID != nil || $0.environment == watch.environment)
            }
            if exists { continue }
            watches.append(watch)
            lastRepository = watch.repository
            added = true
        }
        return added
    }

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Deploy Status/Watchlist.json")
    }
    static func read() throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
}
