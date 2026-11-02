import XCTest
import Foundation
import AppKit
import Carbon
@testable import FindDuck

@MainActor final class NotesRoundTwoTests:XCTestCase {
    private func base() throws->URL {let url=FileManager.default.temporaryDirectory.appendingPathComponent("findduck-round2-"+UUID().uuidString);try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url.resolvingSymlinksInPath()}
    private func wait(_ condition:()->Bool) async->Bool {let limit=Date().addingTimeInterval(10);while Date()<limit {if condition() {return true};try? await Task.sleep(for:.milliseconds(50))};return condition()}
    private func assertWait(_ condition:()->Bool,file:StaticString=#filePath,line:UInt=#line) async {let result=await wait(condition);XCTAssertTrue(result,file:file,line:line)}
    func testHomeFilesMigrationPinAndReorder() throws {
        let folder=try base(),file=folder.appendingPathComponent("报告.txt"),storage=folder.appendingPathComponent("home.json")
        try Data("test".utf8).write(to:file)
        let old=HomeShortcut(title:"个人文件夹",kind:.folder,target:folder.path)
        struct Old:Codable {let items:[HomeShortcut];let resumeWindowSeconds:Double}
        try JSONEncoder().encode(Old(items:[old],resumeWindowSeconds:120)).write(to:storage)
        let home=HomeLibrary(storage:storage,seedDefaults:false)
        XCTAssertEqual(home.items.first?.id,old.id);XCTAssertEqual(home.items.first?.group,3)
        XCTAssertTrue(home.pin(file));XCTAssertFalse(home.pin(file));XCTAssertFalse(home.pin(URL(string:"https://example.com/a.pdf")!))
        XCTAssertEqual(home.items.last?.kind,.file)
        home.move(id:home.items.last!.id,to:home.items.first!)
        XCTAssertEqual(home.items.first?.target,file.path)
        let restored=HomeLibrary(storage:storage,seedDefaults:false)
        XCTAssertEqual(restored.items,home.items)
        try FileManager.default.removeItem(at:folder)
    }
    func testCurrencyConversionAndInputValidation() throws {
        let rates=[ExchangeRate(date:"2026-11-02",base:"CNY",quote:"USD",rate:0.125),ExchangeRate(date:"2026-11-02",base:"CNY",quote:"EUR",rate:0.1)]
        XCTAssertEqual(CurrencyMath.convert(100,from:"USD",to:"CNY",rates:rates),800)
        XCTAssertEqual(CurrencyMath.convert(100,from:"CNY",to:"USD",rates:rates),12.5)
        XCTAssertEqual(CurrencyMath.convert(100,from:"USD",to:"EUR",rates:rates),80)
        XCTAssertEqual(CurrencyMath.convert(-10,from:"USD",to:"CNY",rates:rates),-80)
        XCTAssertEqual(CurrencyMath.convert(100,from:"CNY",to:"CNY",rates:[]),100)
        XCTAssertNil(CurrencyMath.convert(10,from:"USD",to:"JPY",rates:rates))
        XCTAssertEqual(CurrencyMath.amount("1,234.56"),Decimal(string:"1234.56"))
        for invalid in ["","1,23","abc","NaN","1e300","1.123456789"] {XCTAssertNil(CurrencyMath.amount(invalid),invalid)}
    }
    func testTimeConversionHasNoYearAndValidatesCalendarAndDST() throws {
        let iso=ISO8601DateFormatter(),reference=iso.date(from:"2026-07-01T00:00:00Z")!
        let date=try XCTUnwrap(WorldTimes.date(month:12,day:31,hour:23,minute:30,zone:"America/Los_Angeles",reference:reference))
        XCTAssertEqual(WorldTimes.formatted(date,zone:"Asia/Shanghai",format:"MM月dd日 HH:mm"),"01月01日 15:30")
        XCTAssertNil(WorldTimes.date(month:2,day:30,hour:10,minute:0,zone:"Asia/Shanghai",reference:reference))
        XCTAssertNil(WorldTimes.date(month:3,day:8,hour:2,minute:30,zone:"America/New_York",reference:reference))
        XCTAssertNil(WorldTimes.date(month:13,day:1,hour:0,minute:0,zone:"Asia/Shanghai",reference:reference))
        XCTAssertNotNil(WorldTimes.date(month:2,day:29,hour:10,minute:0,zone:"Asia/Shanghai",reference:iso.date(from:"2024-07-01T00:00:00Z")!))
        XCTAssertNil(WorldTimes.date(month:2,day:29,hour:10,minute:0,zone:"Asia/Shanghai",reference:reference))
    }
    func testFKeysAreAllowedAloneButNormalKeysAreNot() throws {
        XCTAssertEqual(HotKeySettings.functionKeys.count,12)
        for code in HotKeySettings.functionKeys {
            XCTAssertTrue(HotKeySettings.allowed(keyCode:code,modifiers:0))
            let event=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.function],timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:UInt16(code)))
            XCTAssertEqual(HotKeySettings.from(event)?.modifiers,0)
            XCTAssertTrue(HotKeySettings.from(event)?.label.hasPrefix("F") == true)
        }
        for code:UInt32 in [0,49,36,105] {XCTAssertFalse(HotKeySettings.allowed(keyCode:code,modifiers:0))}
        XCTAssertFalse(HotKeySettings.allowed(keyCode:122,modifiers:UInt32(shiftKey)))
        XCTAssertTrue(HotKeySettings.allowed(keyCode:49,modifiers:UInt32(controlKey)))
    }
    func testKeywordHighlightRangesKeepUnicodeAndMultipleMatches() {
        let name="😀小猿24年-小猿.xlsx"
        let ranges=KeywordHighlights.ranges(name,query:"小猿 24")
        XCTAssertEqual(ranges.count,3)
        XCTAssertEqual((name as NSString).substring(with:ranges[0]),"小猿")
        XCTAssertEqual(ranges[0].location,2)
        XCTAssertEqual(KeywordHighlights.ranges("Report.pdf",query:"report").first,NSRange(location:0,length:6))
    }
    func testDockBadgeValuesAreOnlyActualCounts() {
        XCTAssertEqual(DockBadgeStore.normalized("12"),"12")
        XCTAssertEqual(DockBadgeStore.normalized("99+"),"99+")
        XCTAssertEqual(DockBadgeStore.normalized("1,234"),"999+")
        for value in ["0","","●","运行中","12 条通知"] {XCTAssertNil(DockBadgeStore.normalized(value))}
    }
    func testDockBadgeBundleLookupRejectsNonApplications() throws {
        for url in [URL(string:"https://example.com")!,URL(fileURLWithPath:"/"),URL(fileURLWithPath:"/tmp/plain.txt")] {
            XCTAssertNil(DockBadgeStore.applicationIdentifier(url))
        }
        let root=try base(),app=root.appendingPathComponent("Fixture.app"),contents=app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at:contents,withIntermediateDirectories:true)
        let data=try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"test.fixture"],format:.xml,options:0)
        try data.write(to:contents.appendingPathComponent("Info.plist"))
        XCTAssertEqual(DockBadgeStore.applicationIdentifier(app),"test.fixture")
        try Data("invalid plist".utf8).write(to:contents.appendingPathComponent("Info.plist"))
        XCTAssertNil(DockBadgeStore.applicationIdentifier(app))
    }
    func testTagEditPreservesCurrentResultsAndUnusedTagsAreHidden() async throws {
        let folder=try base(),root=folder.appendingPathComponent("files"),storage=folder.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for name in ["报告A.txt","报告B.txt","报告C.txt"] {try Data("test".utf8).write(to:root.appendingPathComponent(name))}
        let model=SearchLibrary(storage:storage);model.preferences.suppressNoise=false;model.preferences.developerBlacklist=[]
        var options=LocalIndexOptions();options.indexSystemDirs=true;model.preferences.localIndexOptions=options;model.add(root,kind:.local)
        defer {model.shutdown()}
        await assertWait {model.hasIndex && !model.isIndexing}
        model.query="报告";model.search()
        await assertWait {model.hits.count==3 && !model.isSearching}
        let before=model.hits.map(\.id),last=try XCTUnwrap(model.hits.last)
        let tag=try XCTUnwrap(model.createTag(name:"常用",color:.purple,applyTo:last))
        await assertWait {!model.isSearching && model.visibleTags.contains(tag)}
        XCTAssertEqual(model.hits.map(\.id),before)
        model.search();await assertWait {!model.isSearching};XCTAssertEqual(model.hits.map(\.id),before)
        model.query="报告 ";model.search();await assertWait {!model.isSearching}
        // Trimming-only changes are the same query; changing a real search condition unlocks priority.
        model.resultSort = .name;await assertWait {!model.isSearching}
        XCTAssertEqual(model.hits.first?.id,last.id)
        _=model.createTag(name:"",color:.blue,applyTo:last)
        var custom=model.preferences.customTags ?? [];custom.append(FileTag(id:"unused",name:"空标签",color:.red));model.preferences.customTags=custom
        XCTAssertFalse(model.visibleTags.contains {$0.id=="unused"})
        model.setTag(last,.builtin(.red),enabled:true)
        await assertWait {model.visibleTags.count==2}
        XCTAssertEqual(model.visibleTags.first?.name,"常用")
        model.setTag(last,tag,enabled:false)
        await assertWait {!model.visibleTags.contains {$0.id==tag.id}}
        model.toggleDirectory(root);XCTAssertEqual(model.directoryScope?.path,root.path)
        model.toggleDirectory(root);XCTAssertNil(model.directoryScope)
        model.toggleShared();XCTAssertEqual(model.sourceFilter,.shared)
        model.toggleShared();XCTAssertEqual(model.sourceFilter,.all)
        model.toggleQuick(.recent);XCTAssertEqual(model.quickScope,.recent)
        model.toggleQuick(.recent);XCTAssertEqual(model.quickScope,.none)
    }
}
