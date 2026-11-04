import XCTest
@testable import FindDuck

@MainActor final class WorldClockCustomizationTests:XCTestCase {
    func testCustomCitiesPersistAndUseSelectedTimeZones() {
        let suite="findduck-world-clock-test-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let library=WorldClockLibrary(defaults:defaults)
        XCTAssertTrue(library.add(name:"温哥华",zone:"America/Vancouver"))
        XCTAssertTrue(library.add(name:"广州",zone:"Asia/Shanghai"))
        XCTAssertFalse(library.add(name:" 温哥华 ",zone:"Europe/London"))
        XCTAssertFalse(library.add(name:"无效",zone:"Not/A_Time_Zone"))
        let loaded=WorldClockLibrary(defaults:defaults)
        XCTAssertEqual(loaded.custom.count,2)
        XCTAssertEqual(loaded.zones.filter {$0.zone == "Asia/Shanghai"}.count,2)
        loaded.remove(loaded.custom[0])
        XCTAssertEqual(WorldClockLibrary(defaults:defaults).custom.map(\.name),["广州"])
    }
    func testBuiltInCityCanBeRemovedAndAddedBack() {
        let suite="findduck-world-clock-test-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let library=WorldClockLibrary(defaults:defaults)
        let tokyo=WorldTimes.zones[1]
        library.remove(tokyo)
        XCTAssertFalse(library.zones.contains(tokyo))
        let restored=WorldClockLibrary(defaults:defaults)
        XCTAssertFalse(restored.zones.contains(tokyo))
        XCTAssertTrue(restored.add(name:tokyo.name,zone:tokyo.zone))
        XCTAssertEqual(restored.zones.filter {$0.id == tokyo.id}.count,1)
    }
    func testNamedTagsShareRowsAndWrapWhenNeeded() {
        let short=["库存","终稿","待办"].enumerated().map {FileTag(id:"test:\($0.offset)",name:$0.element,color:.blue)}
        let oneRow=NamedTagsMenuView(tags:short,selected:{_ in false},toggle:{_ in})
        XCTAssertEqual(oneRow.frame.height,30)
        let wrapped=NamedTagsMenuView(tags:short+short,selected:{_ in false},toggle:{_ in})
        XCTAssertGreaterThan(wrapped.frame.height,30)
        XCTAssertEqual(wrapped.subviews.count,6)
    }
}
