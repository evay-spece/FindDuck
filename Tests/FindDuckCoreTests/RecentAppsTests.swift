import XCTest
import Foundation
@testable import FindDuck

@MainActor final class RecentAppsTests:XCTestCase {
    func testRecencyDeduplicationCapacityAndReload() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:folder)}
        let file=folder.appendingPathComponent("recent.json"),store=RecentAppLibrary(file:file,watch:false)
        for i in 0..<25 {
            let app=folder.appendingPathComponent("App\(i).app");try FileManager.default.createDirectory(at:app,withIntermediateDirectories:true)
            store.record(RecentAppEntry(path:app.path,name:"App\(i)",bundleID:"test.\(i)",openedAt:Date(timeIntervalSince1970:Double(i))))
        }
        XCTAssertEqual(store.items.count,20);XCTAssertEqual(store.items.first?.name,"App24")
        let newest=try XCTUnwrap(store.items.first)
        store.record(RecentAppEntry(path:newest.path,name:newest.name,bundleID:newest.bundleID,openedAt:Date(timeIntervalSince1970:0)))
        XCTAssertEqual(store.items.first,newest)
        let old=try XCTUnwrap(store.items.last)
        store.record(RecentAppEntry(path:old.path,name:old.name,bundleID:old.bundleID,openedAt:Date(timeIntervalSince1970:100)))
        XCTAssertEqual(store.items.first?.id,old.id);XCTAssertEqual(store.items.count,20)
        store.record(RecentAppEntry(path:"/Applications/找鸭.app",name:"找鸭",bundleID:"com.chenhuang.smbsearch",openedAt:Date()))
        store.record(RecentAppEntry(path:"/tmp/not-an-app.txt",name:"file",bundleID:nil,openedAt:Date()))
        XCTAssertEqual(store.items.count,20)
        XCTAssertEqual(RecentAppLibrary(file:file,watch:false).items,store.items)
    }
    func testVisibleAppsExcludePinnedPathsAndBundleAliases() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:folder)}
        let file=folder.appendingPathComponent("recent.json"),store=RecentAppLibrary(file:file,watch:false)
        for i in 0..<8 {store.record(RecentAppEntry(path:"/Applications/Test\(i).app",name:"Test\(i)",bundleID:"test.\(i)",openedAt:Date(timeIntervalSince1970:Double(i))))}
        XCTAssertEqual(store.visible(excluding:[]).count,5)
        let alias=folder.appendingPathComponent("Alias.app"),contents=alias.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at:contents,withIntermediateDirectories:true)
        try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"test.7"],format:.xml,options:0).write(to:contents.appendingPathComponent("Info.plist"))
        let pins=[HomeShortcut(title:"Alias",kind:.application,target:alias.path),HomeShortcut(title:"Test6",kind:.application,target:"/Applications/Test6.app")]
        XCTAssertEqual(store.visible(excluding:pins).map(\.name),["Test5","Test4","Test3","Test2","Test1"])
        store.record(RecentAppEntry(path:"/Applications/AnotherPath.app",name:"Test5 renamed",bundleID:"test.5",openedAt:Date(timeIntervalSince1970:100)))
        XCTAssertEqual(store.items.filter {$0.bundleID == "test.5"}.count,1)
    }
}
