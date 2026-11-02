import XCTest
import Foundation
@testable import FindDuck

@MainActor final class HomeReorderTests:XCTestCase {
    func testNativeDragLifecycleSelectorsAreExposed() {
        let surface=HomeItemInteraction.Surface()
        XCTAssertTrue(surface.responds(to:NSSelectorFromString("draggingSession:movedToPoint:")))
        XCTAssertTrue(surface.responds(to:NSSelectorFromString("draggingSession:endedAtPoint:operation:")))
    }
    func testLivePreviewDoesNotPersistUntilDropAndCancelRestores() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:folder)}
        let storage=folder.appendingPathComponent("home.json"),home=HomeLibrary(storage:storage,seedDefaults:false)
        for name in ["A","B","C"] {_=home.add(title:name,kind:.application,target:"/Applications/"+name+".app")}
        let before=try Data(contentsOf:storage),original=home.items
        let drag=HomeReorderState()
        for (index,item) in original.enumerated() {drag.record(item.id,frame:CGRect(x:index*100,y:0,width:80,height:80))}
        drag.begin(original[0].id,items:home.items);drag.update(CGPoint(x:240,y:40))
        XCTAssertEqual(drag.entries(home.items,group:0).map(\.title),["B","C","A"])
        XCTAssertEqual(home.items,original);XCTAssertEqual(try Data(contentsOf:storage),before)
        // Frozen slots prevent oscillation when the destination view animates away.
        drag.update(CGPoint(x:140,y:40));drag.update(CGPoint(x:140,y:40))
        XCTAssertEqual(drag.entries(home.items,group:0).map(\.title),["B","A","C"])
        drag.update(CGPoint(x:1000,y:1000));XCTAssertEqual(drag.entries(home.items,group:0),original)
        drag.end();XCTAssertEqual(drag.entries(home.items,group:0),original)
        XCTAssertEqual(try Data(contentsOf:storage),before)
        drag.begin(original[2].id,items:home.items);drag.update(CGPoint(x:40,y:40));drag.commit(to:home)
        XCTAssertEqual(home.items.map(\.title),["C","A","B"])
        XCTAssertEqual(HomeLibrary(storage:storage,seedDefaults:false).items,home.items)
        XCTAssertNil(drag.draggedID)
    }
    func testReorderRejectsCrossGroupOrDuplicateIDs() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:folder)}
        let home=HomeLibrary(storage:folder.appendingPathComponent("home.json"),seedDefaults:false)
        _=home.add(title:"A",kind:.application,target:"/Applications/A.app")
        _=home.add(title:"Site",kind:.website,target:"https://example.com")
        _=home.add(title:"B",kind:.application,target:"/Applications/B.app")
        let original=home.items,a=original[0].id,b=original[2].id
        home.reorder(group:0,ids:[a,a]);XCTAssertEqual(home.items,original)
        home.reorder(group:0,ids:[a,original[1].id]);XCTAssertEqual(home.items,original)
        home.reorder(group:0,ids:[b,a]);XCTAssertEqual(home.items.map(\.title),["B","Site","A"])
    }
    func testLazyGridMissingOffscreenFramesStillAllowsVisibleSlots() {
        let items=["A","B","C"].map {HomeShortcut(title:$0,kind:.application,target:"/Applications/"+$0+".app")}
        let drag=HomeReorderState()
        drag.record(items[1].id,frame:CGRect(x:0,y:0,width:80,height:80))
        drag.record(items[2].id,frame:CGRect(x:100,y:0,width:80,height:80))
        drag.begin(items[2].id,items:items);drag.update(CGPoint(x:40,y:40))
        XCTAssertEqual(drag.entries(items,group:0).map(\.title),["A","C","B"])
        XCTAssertFalse(drag.accepts(items[2].id,group:3))
        XCTAssertTrue(drag.accepts(items[2].id,group:0))
    }
    func testMultiRowPreviewUsesFrozenSlots() {
        let items=["A","B","C","D"].map {HomeShortcut(title:$0,kind:.application,target:"/Applications/"+$0+".app")}
        let drag=HomeReorderState()
        for (index,item) in items.enumerated() {drag.record(item.id,frame:CGRect(x:(index%2)*100,y:(index/2)*100,width:80,height:80))}
        drag.begin(items[0].id,items:items);drag.update(CGPoint(x:140,y:140))
        XCTAssertEqual(drag.entries(items,group:0).map(\.title),["B","C","D","A"])
        drag.record(items[3].id,frame:CGRect(x:0,y:100,width:80,height:80))
        drag.update(CGPoint(x:140,y:140))
        XCTAssertEqual(drag.entries(items,group:0).map(\.title),["B","C","D","A"])
        drag.update(CGPoint(x:40,y:40));XCTAssertEqual(drag.entries(items,group:0),items)
    }
}
