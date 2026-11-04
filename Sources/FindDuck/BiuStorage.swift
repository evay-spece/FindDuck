import Foundation

enum BiuStorage {
    static let identifier = "com.rocketduck.app"
    // Keep the previous domain solely to import existing installations.
    static let legacyIdentifier = "com.chenhuang.smbsearch"

    static let directory: URL = {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let destination = support.appendingPathComponent(identifier, isDirectory: true)
        let legacy = support.appendingPathComponent(legacyIdentifier, isDirectory: true)
        guard Bundle.main.bundleIdentifier == identifier,
              !manager.fileExists(atPath: destination.path),
              manager.fileExists(atPath: legacy.path) else { return destination }

        let staging = support.appendingPathComponent(".rocketduck-migration-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        do {
            try manager.copyItem(at: legacy, to: staging)
            try manager.moveItem(at: staging, to: destination)
            return destination
        } catch {
            if manager.fileExists(atPath: destination.path) { return destination }
            NSLog("Biu data migration failed: %@", error.localizedDescription)
            return legacy
        }
    }()

    static func migratePreferences() {
        guard Bundle.main.bundleIdentifier == identifier else { return }
        let defaults = UserDefaults.standard
        let marker = "didImportPreviousPreferences"
        guard !defaults.bool(forKey: marker) else { return }
        let previous = defaults.persistentDomain(forName: legacyIdentifier) ?? [:]
        let current = defaults.persistentDomain(forName: identifier) ?? [:]
        var merged = previous.merging(current) { _, current in current }
        merged[marker] = true
        defaults.setPersistentDomain(merged, forName: identifier)
    }
}
