import XCTest
import CoreServices
@testable import OilFindCore

final class M26CoreTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindM26Core-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func contains(_ name: String, root: URL, store: IndexStore) -> Bool { store.read { store.containsPath(root.appendingPathComponent(name).path) } }
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    func testScanExtensionRulesAndCoverage() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.log", "b.LOG", "many.parts.Js", "plain", "last.", "a.log.txt", "long.longextension", "bundle.pages"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        for name in ["folder.log", "App.app", "Document.pages"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        let config = IndexConfig(rootPath: root.path, indexPackageContents: true, excludedExtensions: [".LOG", "js", "app", "pages", "longextension"])
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 2).run()), config: config)
        for name in ["a.log", "b.LOG", "many.parts.Js", "long.longextension", "bundle.pages"] { XCTAssertFalse(contains(name, root: root, store: store), name) }
        for name in ["plain", "last.", "a.log.txt", "folder.log", "App.app", "Document.pages"] { XCTAssertTrue(contains(name, root: root, store: store), name) }
        XCTAssertEqual(store.coverage[.fileType].count, 5)
        XCTAssertEqual(Coverage.explain(path: root.appendingPathComponent("a.log").path, config: config, store: store), .fileType("log"))
        XCTAssertEqual(Coverage.explain(path: root.appendingPathComponent("folder.log").path, config: config, store: store), .indexed)
        XCTAssertNotEqual(config.fingerprint, IndexConfig(rootPath: root.path).fingerprint)
        XCTAssertEqual(config.fingerprint, IndexConfig(rootPath: root.path, indexPackageContents: true, excludedExtensions: ["js", "log", "app", "pages", "longextension"]).fingerprint)
        let db = root.appendingPathComponent("catalog")
        try store.save(to: db.path)
        let loaded = try XCTUnwrap(IndexStore.load(from: db.path))
        XCTAssertEqual(loaded.scopeFingerprint, config.scopeFingerprint)
        XCTAssertEqual(loaded.coverage[.fileType], store.coverage[.fileType])
        XCTAssertEqual(store.read { store.compacted().scopeFingerprint }, config.scopeFingerprint)
    }
    func testDirectAndSubtreeEventsRespectFileTypes() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("rename.txt"))
        let config = IndexConfig(rootPath: root.path, indexPackageContents: true, excludedExtensions: ["log", "js", "app"])
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        store.write { store.buildHash() }
        let updater = IndexUpdater(config: config)
        try FileManager.default.moveItem(at: root.appendingPathComponent("rename.txt"), to: root.appendingPathComponent("rename.LOG"))
        try Data().write(to: root.appendingPathComponent("new.Js"))
        try Data().write(to: root.appendingPathComponent("new.txt"))
        _ = updater.apply(["rename.txt", "rename.LOG", "new.Js", "new.txt"].map { FSChange(path: root.appendingPathComponent($0).path) }, to: store)
        XCTAssertFalse(contains("rename.txt", root: root, store: store))
        XCTAssertFalse(contains("rename.LOG", root: root, store: store))
        XCTAssertFalse(contains("new.Js", root: root, store: store))
        XCTAssertTrue(contains("new.txt", root: root, store: store))
        XCTAssertEqual(store.coverage[.fileType].count, 2)
        for name in ["folder.log", "App.app"] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent("skip.LOG"))
            try Data().write(to: dir.appendingPathComponent("keep.txt"))
        }
        _ = updater.apply([FSChange(path: root.path, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs))], to: store)
        for name in ["folder.log", "App.app"] {
            XCTAssertTrue(contains(name, root: root, store: store))
            XCTAssertTrue(contains(name + "/keep.txt", root: root, store: store))
            XCTAssertFalse(contains(name + "/skip.LOG", root: root, store: store))
        }
    }
    func testSharedSettingsRebuildEveryOnlineSource() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "OilFindM26-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let managers = try ["one", "two"].map { name -> IndexManager in
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent("keep.txt"))
            try Data().write(to: dir.appendingPathComponent("skip.LOG"))
            let manager = IndexManager(config: IndexConfig(rootPath: dir.path), dbURL: root.appendingPathComponent(name + ".index"), settingsDefaults: defaults)
            manager.start(); return manager
        }
        defer { managers.forEach { $0.stop() } }
        wait { managers.allSatisfy { $0.state == .ready } }
        let oldStores = managers.compactMap(\.store)
        let normalized = SettingsPreferences.setExcludedExtensions(" .LOG, log  .Js , css ", in: defaults)
        XCTAssertEqual(normalized, "log js css")
        wait { managers.enumerated().allSatisfy { $0.element.store !== oldStores[$0.offset] && $0.element.state == .ready && !$0.element.isRescanning } }
        for (index, manager) in managers.enumerated() {
            let store = try XCTUnwrap(manager.store)
            XCTAssertNotEqual(store.configFingerprint, oldStores[index].configFingerprint)
            XCTAssertFalse(store.read { store.containsPath(store.rootPath + "/skip.LOG") })
            XCTAssertEqual(manager.explain(path: store.rootPath + "/skip.LOG"), .fileType("log"))
        }
    }
    func testOfflineFilteringIsReversibleAndNeverOverwritesCatalog() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("skip.log"))
        try Data().write(to: root.appendingPathComponent("keep.txt"))
        let config = IndexConfig(rootPath: root.path)
        let initial = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let db = root.appendingPathComponent("catalog")
        try initial.save(to: db.path)
        let original = try Data(contentsOf: db)
        let suite = "OilFindM26Offline-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        _ = SettingsPreferences.setExcludedExtensions("log", in: defaults)
        let manager = IndexManager(config: config, dbURL: db, settingsDefaults: defaults)
        defer { manager.stop() }
        manager.startOffline()
        wait { manager.state == .ready }
        XCTAssertFalse(contains("skip.log", root: root, store: try XCTUnwrap(manager.store)))
        XCTAssertTrue(contains("keep.txt", root: root, store: try XCTUnwrap(manager.store)))
        XCTAssertFalse(manager.isRescanning)
        _ = SettingsPreferences.setExcludedExtensions("", in: defaults)
        wait { manager.state == .ready && manager.store?.read { manager.store!.containsPath(root.appendingPathComponent("skip.log").path) } == true }
        manager.stop()
        XCTAssertEqual(try Data(contentsOf: db), original)
    }
}

extension M26CoreTests {
    func testUnicodeExtensionCaseAndNormalizationMatchScanningAndEvents() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let names = ["one.É", "two.e\u{301}", "three.Ö", "four.İ", "five.ẞ", "six.longextension", "seven.J\u{030C}", "eight.ǰ", "nine.SS"]
        for name in names { try Data().write(to: root.appendingPathComponent(name)) }
        let config = IndexConfig(rootPath: root.path, excludedExtensions: ["é", "ö", "i\u{307}", "ß", "longextension", "ǰ"])
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        XCTAssertEqual(store.liveCount, 1)
        XCTAssertEqual(store.coverage[.fileType].count, UInt64(names.count))
        for name in ["direct.É", "direct.e\u{301}", "direct.Ö"] {
            try Data().write(to: root.appendingPathComponent(name))
            _ = IndexUpdater(config: config).apply([FSChange(path: root.appendingPathComponent(name).path)], to: store)
        }
        let dir = root.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names { try Data().write(to: dir.appendingPathComponent(name)) }
        _ = IndexUpdater(config: config).apply([FSChange(path: dir.path)], to: store)
        XCTAssertEqual(store.liveCount, 2)
    }
}
