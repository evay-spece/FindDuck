import XCTest
import Foundation
import Darwin
@preconcurrency import OilFindCore
@testable import FindDuck

@MainActor final class MigrationTests:XCTestCase {
    private func fixture() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("findduck-oil-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let real=realpath(root.path,nil)!;defer {free(real)};return URL(fileURLWithPath:String(cString:real))
    }
    private func put(_ url:URL,_ content:String="test") throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(content.utf8).write(to:url)
    }
    private func wait(_ seconds:Double=12,_ condition:()->Bool) async -> Bool {
        let deadline=Date().addingTimeInterval(seconds)
        while Date()<deadline {if condition() {return true};try? await Task.sleep(for:.milliseconds(50))}
        return condition()
    }
    private func contains(_ engine:OilLocalEngine,_ url:URL)->Bool {
        guard let handle=engine.handle else {return false}
        return handle.store.read {handle.store.containsPath(url.path)}
    }
    func testNativeChangesAndRestartReplay() async throws {
        let base=try fixture(),root=base.appendingPathComponent("files"),db=base.appendingPathComponent("local.idx")
        let old=root.appendingPathComponent("原有报告.pdf"),fresh=root.appendingPathComponent("新增实时.xlsx"),renamed=root.appendingPathComponent("改名实时.xlsx")
        try put(old)
        let config=IndexConfig(rootPath:root.path,indexUserLibrary:true,indexSystemDirs:true)
        let engine=OilLocalEngine(id:"test",root:root,config:config,database:db,automatic:true)
        print("TEST_ROOT",root.path,"CONFIG",config.rootPath)
        engine.box.manager.onApply={summary in print("APPLIED",summary.inserted,summary.updated,summary.removed,summary.scannedDirs)}
        let ready=await wait {engine.hasIndex && !engine.isScanning};XCTAssertTrue(ready)
        XCTAssertTrue(contains(engine,old))
        try put(fresh)
        let added=await wait {contains(engine,fresh)}
        if !added,let handle=engine.handle {handle.store.read {print("STORE_ROOT",handle.store.rootPath,"ITEMS",(0..<handle.store.count).map {handle.store.path(UInt32($0))})}}
        XCTAssertTrue(added,"Native FSEvents must collect a new file")
        try FileManager.default.moveItem(at:fresh,to:renamed)
        let moved=await wait {contains(engine,renamed) && !contains(engine,fresh)};XCTAssertTrue(moved)
        try FileManager.default.removeItem(at:renamed)
        let removed=await wait {!contains(engine,renamed)};XCTAssertTrue(removed)
        engine.stop();XCTAssertTrue(FileManager.default.fileExists(atPath:db.path))
        let offline=root.appendingPathComponent("停机新增.pdf");try put(offline)
        try? await Task.sleep(for:.seconds(1))
        let restarted=OilLocalEngine(id:"test",root:root,config:config,database:db,automatic:true)
        defer {restarted.stop()}
        let replayed=await wait {contains(restarted,offline)};XCTAssertTrue(replayed)
        XCTAssertTrue(restarted.replayedEvents > 0,"Restart must replay history, rather than only load a stale snapshot")
        XCTAssertEqual(restarted.box.manager.scannedCount,0,"A valid native database should avoid rescanning")
    }
    func testSharedImportNativeSearchAndPaging() async {
        let root=URL(fileURLWithPath:"/Volumes/FindDuckSMBFixture"),now=Date(),actor=OilQueryEngine()
        let files=(0..<600).map {n in FileHit(url:root.appendingPathComponent(String(format:"库存报表%04d",n)+(n%2 == 0 ? ".pdf":".xlsx")),modified:now.addingTimeInterval(Double(n)))}
        let snapshot=NameIndex(root:root,created:now,files:files,directories:[])
        var prefs=DuckPreferences();prefs.suppressNoise=false
        let first=await actor.search(local:[],sharedSnapshot:snapshot,term:"库存",category:.all,sort:.modified,preferences:prefs,opened:[:],limit:200)
        XCTAssertEqual(first.total,600);XCTAssertEqual(first.hits.count,200);XCTAssertEqual(first.hits.first?.name,"库存报表0599.xlsx")
        let second=await actor.search(local:[],sharedSnapshot:snapshot,term:"库存",category:.all,sort:.modified,preferences:prefs,opened:[:],limit:400)
        XCTAssertEqual(second.total,600);XCTAssertEqual(first.hits,Array(second.hits.prefix(200)))
        let pdf=await actor.search(local:[],sharedSnapshot:snapshot,term:"库存",category:.pdf,sort:.modified,preferences:prefs,opened:[:],limit:500)
        XCTAssertEqual(pdf.total,300);XCTAssertTrue(pdf.hits.allSatisfy {$0.url.pathExtension == "pdf"})
        let pinyin=await actor.search(local:[],sharedSnapshot:snapshot,term:"kcb b",category:.all,sort:.relevance,preferences:prefs,opened:[:],limit:200)
        XCTAssertTrue(pinyin.total > 0)
    }
    func testRecentFiftyBeforeTypeFiltering() async {
        let root=URL(fileURLWithPath:"/Volumes/FindDuckRecentFixture"),now=Date(),actor=OilQueryEngine()
        let files=(0..<100).map {n in FileHit(url:root.appendingPathComponent("文件\(n)"+(n%2 == 0 ? ".pdf":".xlsx")),modified:now)} + (0..<10).map {n in FileHit(url:root.appendingPathComponent("应用\(n)"+(n%2 == 0 ? ".app":".APP")),modified:now)}
        let opened=Dictionary(uniqueKeysWithValues:files.enumerated().map {($0.element.id,now.addingTimeInterval(Double($0.offset)))})
        let snapshot=NameIndex(root:root,created:now,files:files,directories:[])
        let recent=await actor.recentSnapshot(local:[],sharedSnapshot:snapshot,opened:opened,preferences:DuckPreferences())
        XCTAssertEqual(recent.files.count,50)
        XCTAssertTrue(recent.files.allSatisfy {$0.url.pathExtension.lowercased() != "app"})
        let search=SearchAccelerator()
        let pdf=await search.search(index:recent,term:"",category:.pdf,sort:.recent,quick:.recent,preferences:DuckPreferences(),opened:opened,download:root)
        XCTAssertEqual(pdf.total,25)
    }
    func testDirectoryScopeBeforeRankingAndPaging() async {
        let root=URL(fileURLWithPath:"/Volumes/ScopeFixture"),folder=root.appendingPathComponent("库存"),now=Date(),actor=OilQueryEngine()
        let inside=(0..<450).map {FileHit(url:folder.appendingPathComponent("子目录/报表\($0).pdf"),modified:now)}
        let outside=(0..<300).map {FileHit(url:root.appendingPathComponent("库存-其他/报表\($0).pdf"),modified:now)}
        let snapshot=NameIndex(root:root,created:now,files:inside+outside,directories:[])
        var prefs=DuckPreferences();prefs.suppressNoise=false
        let first=await actor.search(local:[],sharedSnapshot:snapshot,term:"报表",category:.pdf,sort:.name,preferences:prefs,opened:[:],limit:200,scopeRoot:folder)
        XCTAssertEqual(first.total,450);XCTAssertEqual(first.hits.count,200)
        XCTAssertTrue(first.hits.allSatisfy {DuckRules.under($0.url,folder)})
        let more=await actor.search(local:[],sharedSnapshot:snapshot,term:"报表",category:.all,sort:.name,preferences:prefs,opened:[:],limit:400,scopeRoot:folder)
        XCTAssertEqual(more.hits.count,400);XCTAssertEqual(first.hits,Array(more.hits.prefix(200)))
        let missing=await actor.search(local:[],sharedSnapshot:snapshot,term:"",category:.all,sort:.name,preferences:prefs,opened:[:],limit:200,scopeRoot:root.appendingPathComponent("不存在"))
        XCTAssertEqual(missing.total,0)
        let parent=await actor.search(local:[],sharedSnapshot:snapshot,term:"报表",category:.pdf,sort:.name,preferences:prefs,opened:[:],limit:1000,scopeRoot:URL(fileURLWithPath:"/Volumes"))
        XCTAssertEqual(parent.total,750)
    }
    func testDirectoryShortcutScopeAndPersistence() async throws {
        let base=try fixture(),root=base.appendingPathComponent("文件"),folder=root.appendingPathComponent("库存"),storage=base.appendingPathComponent("设置")
        try put(folder.appendingPathComponent("报表.pdf"));try put(folder.appendingPathComponent("报表.xlsx"));try put(root.appendingPathComponent("其他/报表.pdf"))
        try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:true)
        var prefs=DuckPreferences();prefs.developerBlacklist=[];prefs.blacklistDefaultsVersion=3;prefs.suppressNoise=false
        var options=LocalIndexOptions();options.indexSystemDirs=true;prefs.localIndexOptions=options
        try JSONEncoder().encode(prefs).write(to:storage.appendingPathComponent("duck-preferences.json"))
        try JSONEncoder().encode([SearchRoot(url:root,kind:.local)]).write(to:storage.appendingPathComponent("sources.json"))
        let library=SearchLibrary(storage:storage);defer {library.shutdown()}
        let ready=await wait {library.hasIndex && !library.isIndexing};XCTAssertTrue(ready)
        library.query="报表";library.addDirectoryShortcut(folder,kind:.local)
        let scoped=await wait {library.resultCount == 2 && !library.isSearching};XCTAssertTrue(scoped)
        XCTAssertEqual(library.scopeTitle,"库存");XCTAssertEqual(library.sources.count,1)
        library.category = .pdf
        let typed=await wait {library.resultCount == 1 && !library.isSearching};XCTAssertTrue(typed)
        library.clearScope()
        let cleared=await wait {library.resultCount == 2 && !library.isSearching};XCTAssertTrue(cleared);XCTAssertEqual(library.query,"报表")
        library.activateShared();XCTAssertEqual(library.scopeTitle,"共享盘");XCTAssertFalse(library.localSelected)
        library.shutdown()
        let restored=SearchLibrary(storage:storage);defer {restored.shutdown()}
        XCTAssertEqual(restored.directoryShortcuts,[folder.standardizedFileURL])
        restored.activateDirectory(folder);XCTAssertEqual(restored.scopeTitle,"库存")
        restored.removeDirectoryShortcut(folder);XCTAssertNil(restored.scopeTitle);XCTAssertTrue(restored.directoryShortcuts.isEmpty)
    }
    func testLegacyPinNoLongerAffectsRanking() async throws {
        let root=URL(fileURLWithPath:"/Volumes/TagFixture"),now=Date(),actor=OilQueryEngine()
        let files=(0..<300).map {FileHit(url:root.appendingPathComponent(String(format:"报表%04d.pdf",$0)),modified:now.addingTimeInterval(Double(-$0)))}
        let legacy=try JSONSerialization.data(withJSONObject:["blacklist":[],"suppressNoise":false,"recentOpened":[:],"pinnedPaths":[files[299].id]])
        let prefs=try JSONDecoder().decode(DuckPreferences.self,from:legacy)
        let snapshot=NameIndex(root:root,created:now,files:files,directories:[])
        for sort in [ResultSort.name,.modified] {
            let result=await actor.search(local:[],sharedSnapshot:snapshot,term:"报表",category:.pdf,sort:sort,preferences:prefs,opened:[:],limit:200)
            XCTAssertEqual(result.hits.first?.id,files[0].id);XCTAssertEqual(result.total,300)
        }
        let compact=SearchAccelerator()
        let result=await compact.search(index:snapshot,term:"报表",category:.pdf,sort:.name,quick:.none,preferences:prefs,opened:[:],download:root)
        XCTAssertEqual(result.hits.first?.id,files[0].id)
    }
    func testMultipleTagsMigratePersistWithoutFinderTagsAndTrashFixture() async throws {
        let base=try fixture(),root=base.appendingPathComponent("文件"),file=root.appendingPathComponent("操作验收.txt"),storage=base.appendingPathComponent("设置")
        try put(file);try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:true)
        var prefs=DuckPreferences();prefs.developerBlacklist=[];prefs.blacklistDefaultsVersion=3;prefs.colorMarks=[file.path:.green]
        try JSONEncoder().encode(prefs).write(to:storage.appendingPathComponent("duck-preferences.json"))
        let originalTags=try file.resourceValues(forKeys:[.tagNamesKey]).tagNames
        let library=SearchLibrary(storage:storage),hit=FileHit(url:file)
        XCTAssertTrue(library.hasTag(hit,.builtin(.green)));XCTAssertNil(library.preferences.colorMarks)
        library.toggleTag(hit,.builtin(.purple));library.toggleTag(hit,.builtin(.blue))
        let custom=try XCTUnwrap(library.createTag(name:"待处理",color:.orange,applyTo:hit))
        XCTAssertEqual(library.tags(hit).count,4);XCTAssertTrue(library.hasTag(hit,custom))
        XCTAssertEqual(library.createTag(name:" 待处理 ",color:.orange,applyTo:hit)?.id,custom.id)
        XCTAssertEqual(library.preferences.customTags?.count,1)
        XCTAssertEqual(try file.resourceValues(forKeys:[.tagNamesKey]).tagNames,originalTags)
        library.shutdown()
        let restored=SearchLibrary(storage:storage);defer {restored.shutdown()}
        XCTAssertEqual(restored.tags(hit).count,4);XCTAssertTrue(restored.hasTag(hit,custom))
        restored.toggleTag(hit,.builtin(.purple));XCTAssertEqual(restored.tags(hit).count,3)
        restored.clearTags(hit);XCTAssertTrue(restored.tags(hit).isEmpty);XCTAssertTrue(restored.tagCatalog.contains {$0.id == custom.id})
        await restored.trash(hit)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path));XCTAssertTrue(restored.status.hasPrefix("已移到废纸篓"))
        XCTAssertThrowsError(try FileOperations.trash(root.appendingPathComponent("不存在.txt")))
    }
    func testEscapeConsumesKeywordThenScopeThenRequestsHide() throws {
        let base=try fixture(),library=SearchLibrary(storage:base.appendingPathComponent("settings"));defer {library.shutdown()}
        library.activateShared();library.query="关键词"
        XCTAssertTrue(library.consumeEscape());XCTAssertEqual(library.query,"");XCTAssertEqual(library.scopeTitle,"共享盘")
        XCTAssertTrue(library.consumeEscape());XCTAssertNil(library.scopeTitle)
        XCTAssertFalse(library.consumeEscape())
        library.query="仅关键词";XCTAssertTrue(library.consumeEscape());XCTAssertFalse(library.consumeEscape())
    }
    func testHomepagePersistenceValidationAndResumeWindow() throws {
        let base=try fixture(),storage=base.appendingPathComponent("home.json"),home=HomeLibrary(storage:storage,seedDefaults:false)
        XCTAssertTrue(HomeLibrary.shouldShowHome(elapsed:nil,resumeWindow:120))
        XCTAssertFalse(HomeLibrary.shouldShowHome(elapsed:30,resumeWindow:120))
        XCTAssertFalse(HomeLibrary.shouldShowHome(elapsed:120,resumeWindow:120))
        XCTAssertTrue(HomeLibrary.shouldShowHome(elapsed:121,resumeWindow:120))
        XCTAssertTrue(home.add(title:"网站一",kind:.website,target:"example.com"))
        XCTAssertFalse(home.add(title:"重复",kind:.website,target:"https://example.com"))
        XCTAssertFalse(home.add(title:"不安全",kind:.website,target:"file:///etc/passwd"))
        XCTAssertFalse(home.add(title:"带密码",kind:.website,target:"https://user:secret@example.com"))
        XCTAssertTrue(home.add(title:"软件",kind:.application,target:"/Applications/Fixture.app"))
        XCTAssertTrue(home.add(title:"网站二",kind:.website,target:"https://example.org"))
        let first=home.items[0],second=home.items[2];home.move(second,by:-1)
        XCTAssertEqual(home.items.filter {$0.group == 1}.map(\.id),[second.id,first.id])
        home.rename(first,title:"我的网站");home.resumeWindowSeconds=300
        let restored=HomeLibrary(storage:storage,seedDefaults:false)
        XCTAssertEqual(restored.items,home.items);XCTAssertEqual(restored.resumeWindowSeconds,300)
        restored.remove(first);XCTAssertFalse(restored.items.contains {$0.id == first.id})
    }
    func testHistoryTenDedupRecallAndQuickFilterPreservesKeyword() async throws {
        let base=try fixture(),root=base.appendingPathComponent("files"),wechat=root.appendingPathComponent("wechat"),storage=base.appendingPathComponent("settings")
        try put(wechat.appendingPathComponent("库存.pdf"));try put(wechat.appendingPathComponent("库存.xlsx"));try put(wechat.appendingPathComponent("计划.pdf"))
        try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:true)
        var prefs=DuckPreferences();prefs.developerBlacklist=[];prefs.blacklistDefaultsVersion=3;prefs.suppressNoise=false;prefs.wechatFolder=wechat
        var options=LocalIndexOptions();options.indexSystemDirs=true;prefs.localIndexOptions=options
        try JSONEncoder().encode(prefs).write(to:storage.appendingPathComponent("duck-preferences.json"))
        try JSONEncoder().encode([SearchRoot(url:root,kind:.local)]).write(to:storage.appendingPathComponent("sources.json"))
        let library=SearchLibrary(storage:storage);defer {library.shutdown()}
        for term in ["零","一","二","三","四","五","六","七","八","九","十"] {library.rememberSearch(term)}
        XCTAssertEqual(library.searchHistory,["十","九","八","七","六","五","四","三","二","一"])
        library.rememberSearch("三");XCTAssertEqual(library.searchHistory,["三","十","九","八","七","六","五","四","二","一"])
        library.query="库存";library.category = .pdf;library.activateQuick(.wechat)
        let ready=await wait {!library.isSearching && !library.refreshingQuick && library.resultCount == 1};XCTAssertTrue(ready)
        XCTAssertEqual(library.query,"库存");XCTAssertEqual(library.category,.pdf);XCTAssertEqual(library.hits.first?.name,"库存.pdf")
        library.activateShared();XCTAssertEqual(library.query,"库存");XCTAssertEqual(library.category,.pdf)
        library.activateDirectory(root);XCTAssertEqual(library.query,"库存");XCTAssertEqual(library.category,.pdf)
        library.recallSearch("计划");XCTAssertEqual(library.query,"计划");XCTAssertEqual(library.searchHistory.first,"计划")
        library.showHome();XCTAssertEqual(library.query,"");XCTAssertNil(library.scopeTitle)
        library.shutdown()
        let restored=SearchLibrary(storage:storage);defer {restored.shutdown()}
        XCTAssertEqual(restored.searchHistory,library.searchHistory);restored.clearSearchHistory();XCTAssertTrue(restored.searchHistory.isEmpty)
    }
    func testWechatLocationAutoDiscoveryAndMissingCacheRecovery() throws {
        let home=try fixture(),folder=home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files")
        XCTAssertNil(WechatLocations.locate(home:home))
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        XCTAssertEqual(WechatLocations.locate(home:home)?.path,folder.path)
        XCTAssertEqual(WechatLocations.locate(home:home,existing:home.appendingPathComponent("missing"))?.path,folder.path)
        let cached=home.appendingPathComponent("known-wechat");try FileManager.default.createDirectory(at:cached,withIntermediateDirectories:true)
        XCTAssertEqual(WechatLocations.locate(home:home,existing:cached)?.path,cached.path)
    }
    func testWechatIndexOnlyIncludesChatFileAttachments() async throws {
        let base=try fixture();defer {try? FileManager.default.removeItem(at:base)}
        let root=base.appendingPathComponent("xwechat_files"),account=root.appendingPathComponent("account")
        let received=account.appendingPathComponent("msg/file/2026-11/收到报告.pdf")
        let sent=account.appendingPathComponent("FileStorage/File/已发报告.xlsx")
        let image=account.appendingPathComponent("msg/attach/chat/2026-11/照片.jpg")
        let opaque=account.appendingPathComponent("msg/attach/chat/2026-11/1234567890abcdef1234567890abcdef.dat")
        let video=account.appendingPathComponent("msg/video/2026-11/会议视频.mp4")
        let cache=account.appendingPathComponent("cache/缓存报告.pdf")
        let backup=root.appendingPathComponent("old_backup/account/msg/file/备份报告.pdf")
        for file in [received,sent,image,opaque,video,cache,backup] {try put(file)}
        let attachments=WechatLocations.attachmentRoots(in:root)
        XCTAssertEqual(Set(attachments.map(\.standardizedFileURL.path)),Set([received.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path,sent.deletingLastPathComponent().standardizedFileURL.path,image.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path,video.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path]))
        let storage=base.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:true)
        var prefs=DuckPreferences();prefs.developerBlacklist=[];prefs.blacklistDefaultsVersion=3;prefs.suppressNoise=true;prefs.wechatFolder=root
        var options=LocalIndexOptions();options.indexSystemDirs=true;prefs.localIndexOptions=options
        try JSONEncoder().encode(prefs).write(to:storage.appendingPathComponent("duck-preferences.json"))
        try JSONEncoder().encode([SearchRoot(url:root,kind:.local)]).write(to:storage.appendingPathComponent("sources.json"))
        let library=SearchLibrary(storage:storage);defer {library.shutdown()}
        let ready=await wait {library.hasIndex && !library.isIndexing};XCTAssertTrue(ready)
        library.query="报告";library.search()
        let found=await wait {!library.isSearching && library.resultCount == 2};XCTAssertTrue(found)
        XCTAssertEqual(Set(library.hits.map(\.name)),Set([received.lastPathComponent,sent.lastPathComponent]))
        XCTAssertEqual(ResultCategory.kind(of:FileHit(url:image)),.images)
        library.query="会议视频";library.search()
        let videoFound=await wait {!library.isSearching && library.hits.contains {$0.url.standardizedFileURL == video.standardizedFileURL}};XCTAssertTrue(videoFound)
        library.category = .images;library.query="照片";library.search()
        let imageFound=await wait {!library.isSearching && library.hits.contains {$0.url.standardizedFileURL == image.standardizedFileURL}};XCTAssertTrue(imageFound)
        XCTAssertTrue(WechatLocations.isOpaqueImage(opaque))
        XCTAssertEqual(library.sources.count,1)
    }
    func testTodayScannerBypassesStaleIndexAndSkipsOldWechatTree() async throws {
        let base=try fixture(),root=base.appendingPathComponent("xwechat_files"),files=root.appendingPathComponent("account/msg/file")
        let formatter=DateFormatter();formatter.dateFormat="yyyy-MM";let month=formatter.string(from:Date())
        let fresh=files.appendingPathComponent(month+"/今天微信.xlsx"),direct=files.appendingPathComponent("直接附件.pdf"),old=files.appendingPathComponent("2020-01/旧附件.pdf")
        let image=root.appendingPathComponent("account/msg/attach/chat/"+month+"/微信照片.jpg")
        let opaque=root.appendingPathComponent("account/msg/attach/chat/"+month+"/1234567890abcdef1234567890abcdef.dat")
        let video=root.appendingPathComponent("account/msg/video/"+month+"/微信视频.mp4")
        try put(fresh);try put(direct);try put(old);try put(image);try put(opaque);try put(video)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1000)],ofItemAtPath:old.deletingLastPathComponent().path)
        var policy=ScanPolicy();policy.fullScanPause = .zero
        let result=try await TodayQuickScanner.scan(quick:.wechat,root:root,policy:policy)
        XCTAssertTrue(result.files.contains {$0.url.standardizedFileURL.path == fresh.standardizedFileURL.path})
        XCTAssertTrue(result.files.contains {$0.url.standardizedFileURL.path == direct.standardizedFileURL.path})
        XCTAssertTrue(result.files.contains {$0.url.standardizedFileURL.path == image.standardizedFileURL.path})
        XCTAssertTrue(result.files.contains {$0.url.standardizedFileURL.path == video.standardizedFileURL.path})
        XCTAssertFalse(result.files.contains {$0.url.standardizedFileURL.path == opaque.standardizedFileURL.path})
        XCTAssertFalse(result.files.contains {$0.url.path.contains("2020-01")})
        XCTAssertTrue(result.files.contains {DuckRules.today($0)})
        let downloads=base.appendingPathComponent("Downloads"),download=downloads.appendingPathComponent("今天下载.pdf");try put(download)
        let downloaded=try await TodayQuickScanner.scan(quick:.downloads,root:downloads,policy:policy)
        XCTAssertEqual(downloaded.files.count,1);XCTAssertTrue(DuckRules.today(downloaded.files[0]))
    }
    func testSharedDependencyNamesRemainSearchable() async {
        let root=URL(fileURLWithPath:"/Volumes/FindDuckSMBFixture"),files=["node_modules/业务报告.pdf","Tool.app/Contents/业务报告.pdf"].map {FileHit(url:root.appendingPathComponent($0))}
        let result=await OilQueryEngine().search(local:[],sharedSnapshot:NameIndex(root:root,created:Date(),files:files,directories:[]),term:"业务报告",category:.pdf,sort:.relevance,preferences:DuckPreferences(),opened:[:],limit:200)
        XCTAssertEqual(result.total,2)
    }
    func testLegacyWechatCacheDoesNotLeakFromAnotherIndex() async {
        let root=URL(fileURLWithPath:"/Users/fixture")
        let cache=FileHit(url:root.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat/Message/MessageTemp/截图.rar"))
        let attachment=FileHit(url:root.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/account/msg/file/截图.pdf"))
        let result=await OilQueryEngine().search(local:[],sharedSnapshot:NameIndex(root:root,created:Date(),files:[cache,attachment],directories:[]),term:"截图",category:.all,sort:.relevance,preferences:DuckPreferences(),opened:[:],limit:20)
        XCTAssertEqual(result.hits.map(\.name),["截图.pdf"])
    }
    func testLibraryDualBlacklistAndLiveSearch() async throws {
        let base=try fixture(),root=base.appendingPathComponent("files"),storage=base.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:true)
        for name in ["用户排除/报告.pdf","开发者排除/报告.pdf","保留报告.pdf"] {try put(root.appendingPathComponent(name))}
        var prefs=DuckPreferences();prefs.developerBlacklist=[root.appendingPathComponent("开发者排除")];prefs.blacklist=[root.appendingPathComponent("用户排除")];prefs.blacklistDefaultsVersion=3;prefs.suppressNoise=false
        var options=LocalIndexOptions();options.indexSystemDirs=true;prefs.localIndexOptions=options
        try JSONEncoder().encode(prefs).write(to:storage.appendingPathComponent("duck-preferences.json"))
        try JSONEncoder().encode([SearchRoot(url:root,kind:.local)]).write(to:storage.appendingPathComponent("sources.json"))
        let library=SearchLibrary(storage:storage);defer {library.shutdown()}
        let ready=await wait {library.hasIndex && !library.isIndexing};XCTAssertTrue(ready)
        library.query="报告";library.search()
        let found=await wait {!library.isSearching && library.resultCount == 1};XCTAssertTrue(found);XCTAssertEqual(library.hits.first?.name,"保留报告.pdf")
        try put(root.appendingPathComponent("新报告.xlsx"))
        let refreshed=await wait {!library.isSearching && library.resultCount == 2};XCTAssertTrue(refreshed,"Displayed query should refresh after a native filesystem event")
    }
    func testSharedRootParentsAreNotExposed() async {
        let share=URL(fileURLWithPath:"/Volumes/OnlyThisShare"),date=Date()
        let snapshot=NameIndex(root:URL(fileURLWithPath:"/"),created:date,files:[FileHit(url:share.appendingPathComponent("报告.pdf"))],directories:[DirectoryRecord(url:share,checked:date,due:.distantFuture,hotUntil:nil)])
        let engine=OilQueryEngine()
        let result=await engine.search(local:[],sharedSnapshot:snapshot,term:"Volumes",category:.folders,sort:.name,preferences:DuckPreferences(),opened:[:],limit:200)
        XCTAssertEqual(result.total,0)
        let shared=await engine.search(local:[],sharedSnapshot:snapshot,term:"OnlyThisShare",category:.folders,sort:.name,preferences:DuckPreferences(),opened:[:],limit:200)
        XCTAssertEqual(shared.total,1)
    }

    func testSelectedTodayEntryRefreshesOnNewFiles() async throws {
        let base=try fixture(),root=base.appendingPathComponent("files"),wechat=root.appendingPathComponent("wechat"),storage=base.appendingPathComponent("settings")
        try put(wechat.appendingPathComponent("今天微信一.pdf"));try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:true)
        var prefs=DuckPreferences();prefs.developerBlacklist=[];prefs.blacklistDefaultsVersion=3;prefs.suppressNoise=false;prefs.wechatFolder=wechat
        var options=LocalIndexOptions();options.indexSystemDirs=true;prefs.localIndexOptions=options
        try JSONEncoder().encode(prefs).write(to:storage.appendingPathComponent("duck-preferences.json"))
        try JSONEncoder().encode([SearchRoot(url:root,kind:.local)]).write(to:storage.appendingPathComponent("sources.json"))
        let library=SearchLibrary(storage:storage);defer {library.shutdown()}
        library.activateQuick(.wechat)
        let initial=await wait {!library.refreshingQuick && !library.isSearching && library.resultCount == 1};XCTAssertTrue(initial)
        try put(wechat.appendingPathComponent("今天微信二.xlsx"))
        let live=await wait {!library.refreshingQuick && !library.isSearching && library.resultCount == 2};XCTAssertTrue(live)
    }

    func testSharedCaseDistinctNamesRetainSeparateIDs() {
        let root=URL(fileURLWithPath:"/Volumes/CaseShare"),upper=root.appendingPathComponent("Report.pdf"),lower=root.appendingPathComponent("report.pdf")
        let handle=OilSnapshotStore.make(NameIndex(root:root,created:Date(),files:[FileHit(url:upper),FileHit(url:lower)],directories:[]))
        handle.store.read {XCTAssertNotEqual(handle.store.resolve(path:upper.path),handle.store.resolve(path:lower.path))}
    }

}
