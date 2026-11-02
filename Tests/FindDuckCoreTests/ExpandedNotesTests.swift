import XCTest
import Foundation
import AppKit
@testable import FindDuck

@MainActor final class ExpandedNotesTests:XCTestCase {
    func testCalculatorAndInvalidInputs() {
        XCTAssertEqual(DuckCalculator.evaluate("(12+3)*4"),"60")
        XCTAssertEqual(DuckCalculator.evaluate("2+3*4"),"14")
        XCTAssertEqual(DuckCalculator.evaluate("-2^2"),"-4")
        XCTAssertEqual(DuckCalculator.evaluate("200*10%"),"20")
        XCTAssertEqual(DuckCalculator.evaluate("2^3^2"),"512")
        XCTAssertNil(DuckCalculator.evaluate("1/0"));XCTAssertNil(DuckCalculator.evaluate("2+"))
        XCTAssertNil(DuckCalculator.evaluate("report-2.pdf"));XCTAssertNil(DuckCalculator.evaluate("pow(2,4)"))
    }
    func testDisplayPathsPreserveOriginal() {
        let home=URL(fileURLWithPath:"/Users/alice")
        let file=URL(fileURLWithPath:"/Users/alice/Desktop/工作/a.pdf")
        XCTAssertEqual(DisplayPath.parent(file,home:home),"/桌面/工作/")
        XCTAssertEqual(file.path,"/Users/alice/Desktop/工作/a.pdf")
        XCTAssertEqual(DisplayPath.parent(URL(fileURLWithPath:"/Users/bob/Downloads/a.pdf"),home:home),"bob/下载/")
        XCTAssertEqual(DisplayPath.parent(URL(fileURLWithPath:"/Users/alice/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid/msg/file/2026-11/a.pdf"),home:home),"微信文档/2026-11")
    }
    func testAnnotationMatchPriorityScopeAndPaging() async {
        let root=URL(fileURLWithPath:"/Volumes/NotesTest")
        let files=(0..<450).map {FileHit(url:root.appendingPathComponent(String(format:"报告%04d.pdf",$0)))}
        let index=NameIndex(root:root,created:Date(),files:files,directories:[])
        let tagged=files[440],noted=files[441]
        let tag=FileTag(id:"custom",name:"库存",color:.purple)
        var p=DuckPreferences();p.suppressNoise=false;p.customTags=[tag];p.fileTags=[tagged.id:[tag.id]];p.fileNotes=[noted.id:"待确认"]
        let engine=OilQueryEngine()
        let matches=await engine.search(local:[],sharedSnapshot:index,term:"库存",category:.pdf,sort:.relevance,preferences:p,opened:[:],limit:200)
        XCTAssertEqual(matches.hits.map(\.id),[tagged.id]);XCTAssertEqual(matches.total,1)
        let notes=await engine.search(local:[],sharedSnapshot:index,term:"待确认",category:.pdf,sort:.relevance,preferences:p,opened:[:],limit:200)
        XCTAssertEqual(notes.hits.map(\.id),[noted.id])
        let page=await engine.search(local:[],sharedSnapshot:index,term:"报告",category:.pdf,sort:.name,preferences:p,opened:[:],limit:200)
        XCTAssertEqual(page.total,450);XCTAssertEqual(Set(page.hits.prefix(2).map(\.id)),[tagged.id,noted.id])
        p.tagFilter="*"
        let all=await engine.search(local:[],sharedSnapshot:index,term:"",category:.pdf,sort:.name,preferences:p,opened:[:],limit:200)
        XCTAssertEqual(Set(all.hits.map(\.id)),[tagged.id,noted.id]);XCTAssertEqual(all.total,2)
        p.blockedFiles=[tagged.id]
        let blocked=await engine.search(local:[],sharedSnapshot:index,term:"库存",category:.pdf,sort:.relevance,preferences:p,opened:[:],limit:200)
        XCTAssertEqual(blocked.total,0)
        p.blockedFiles=nil
        let outside=await engine.search(local:[],sharedSnapshot:index,term:"库存",category:.pdf,sort:.relevance,preferences:p,opened:[:],limit:200,scopeRoot:root.appendingPathComponent("other"))
        XCTAssertEqual(outside.total,0)
    }
    func testCompactAnnotationsRespectRecent50() async {
        let root=URL(fileURLWithPath:"/tmp/compact-notes")
        let files=(0..<51).map {FileHit(url:root.appendingPathComponent("f\($0).pdf"))}
        let index=NameIndex(root:root,created:Date(),files:files,directories:[])
        var p=DuckPreferences();p.suppressNoise=false;p.customTags=[FileTag(id:"x",name:"库存",color:.red)];p.fileTags=[files[0].id:["x"],files[50].id:["x"]]
        let opened=Dictionary(uniqueKeysWithValues:files.enumerated().map {($0.element.id,Date(timeIntervalSince1970:Double(100-$0.offset)))})
        let result=await SearchAccelerator().search(index:index,term:"库存",category:.pdf,sort:.recent,quick:.recent,preferences:p,opened:opened,download:root)
        XCTAssertEqual(result.hits.map(\.id),[files[0].id])
    }
    func testTagEditDeletionNotesAndBlockedPersistence() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file=FileHit(url:base.appendingPathComponent("a.pdf"))
        let model=SearchLibrary(storage:base)
        let tag=model.createTag(name:"标签",color:.red,applyTo:file)!
        model.updateTag(tag,name:"库存",color:.purple);model.setNote("独立备注",file:file);model.blockFile(file)
        XCTAssertEqual(model.tags(file).first?.name,"库存");XCTAssertEqual(model.tags(file).first?.color,.purple)
        let reload=SearchLibrary(storage:base)
        XCTAssertEqual(reload.preferences.fileNotes?[file.id],"独立备注");XCTAssertTrue(reload.preferences.blockedFiles?.contains(file.id) == true)
        reload.deleteTag(tag);XCTAssertTrue(reload.tags(file).isEmpty);XCTAssertTrue(reload.preferences.annotated(file.id))
        reload.setNote("",file:file);XCTAssertFalse(reload.preferences.annotated(file.id));reload.unblockFile(file.id)
        model.shutdown();reload.shutdown()
        try FileManager.default.removeItem(at:base)
    }
    func testQuickTextAndDragPersist() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model=QuickTextLibrary(file:base.appendingPathComponent("texts.json")),item=QuickText(title:"问候",text:"你好")
        model.save(item);XCTAssertEqual(QuickTextLibrary(file:base.appendingPathComponent("texts.json")).items,[item])
        model.remove(item);XCTAssertTrue(model.items.isEmpty)
        let home=HomeLibrary(storage:base.appendingPathComponent("home.json"),seedDefaults:false)
        XCTAssertTrue(home.add(title:"A",kind:.website,target:"https://a.example"));XCTAssertTrue(home.add(title:"B",kind:.website,target:"https://b.example"))
        home.move(id:home.items[1].id,to:home.items[0]);XCTAssertEqual(home.items.map(\.title),["B","A"])
        XCTAssertEqual(HomeLibrary(storage:base.appendingPathComponent("home.json"),seedDefaults:false).items.map(\.title),["B","A"])
        try FileManager.default.removeItem(at:base)
    }
}

@MainActor final class RocketIconTests:XCTestCase {
    func testTemplateResourceHasRetinaRepsAndTransparency() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let icon=try XCTUnwrap(DuckMenuBarIcon.load(resources:root.appendingPathComponent("Assets")))
        XCTAssertTrue(icon.isTemplate);XCTAssertEqual(icon.size.width,20);XCTAssertEqual(icon.representations.count,3)
        XCTAssertEqual(icon.representations.map(\.pixelsWide).sorted(),[20,40,60])
        let bitmap=try XCTUnwrap(icon.representations.first as? NSBitmapImageRep)
        XCTAssertTrue(bitmap.hasAlpha)
        XCTAssertLessThan(bitmap.colorAt(x:0,y:0)?.alphaComponent ?? 1,0.1)
    }
}
