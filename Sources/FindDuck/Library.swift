import SwiftUI
import AppKit
import Combine
import CryptoKit
import Darwin
@preconcurrency import OilFindCore

enum SourceKind:String,Codable,CaseIterable,Identifiable {case local="本地",shared="共享盘";var id:String {rawValue}}
enum SourceFilter:String,CaseIterable,Identifiable {case all="本地＋共享盘",local="仅本地",shared="仅共享盘";var id:String {rawValue}}
struct SearchRoot:Codable,Identifiable,Equatable {let url:URL;var kind:SourceKind;var id:String {url.standardizedFileURL.path}}
@MainActor final class SearchLibrary:ObservableObject {
    @Published var sources:[SearchRoot]=[]
    @Published var query=""
    @Published var tagFilter:String? {didSet {if !batching {search()}}}
    var isHome:Bool {query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && scopeTitle == nil && tagFilter == nil}
    @Published private(set) var searchHistory:[String]=[]
    private var historyTask:Task<Void,Never>?
    private var historyCandidate=""
    @Published private(set) var directoryShortcuts:[URL]=[]
    @Published private(set) var directoryScope:URL?
    var scopeTitle:String? {directoryScope.map { $0.lastPathComponent.isEmpty ? "/" : $0.lastPathComponent } ?? (quickScope != .none ? quickScope.rawValue : !localSelected && sharedSelected ? "共享盘" : nil)}
    @Published var preferences=DuckPreferences()
    @Published var category:ResultCategory = .all {didSet {if !batching && category != oldValue {search()}}}
    @Published var resultSort:ResultSort = .relevance {didSet {if !batching && resultSort != oldValue {if resultSort == .recent {refreshRecents()};search()}}}
    @Published var quickScope:QuickScope = .none {didSet {if !batching && quickScope != oldValue {search()}}}
    @Published var localSelected=true {didSet {if !batching && localSelected != oldValue {search()}}}
    @Published var sharedSelected=true {didSet {if !batching && sharedSelected != oldValue {search()}}}
    var sourceFilter:SourceFilter {localSelected && sharedSelected ? .all : localSelected ? .local : .shared}
    @Published var hits:[FileHit]=[]
    @Published private(set) var resultCount=0
    @Published var index:NameIndex?
    @Published var isSearching=false
    @Published var status=""
    @Published var deepSearching=false
    @Published var deepStatus=""
    @Published private(set) var refreshingQuick=false
    @Published private(set) var quickRefreshStatus=""
    @Published var autoUpdate=true {didSet {
        for engine in localEngines.values {engine.setAutomatic(autoUpdate)}
        for engine in sharedEngines.values {engine.autoUpdate=autoUpdate}
        saveAuto()
    }}
    private let storage:URL,policy:ScanPolicy,tick:Duration
    private var localEngines:[String:OilLocalEngine]=[:]
    private var sharedEngines:[String:SearchModel]=[:]
    private var subscriptions:[String:AnyCancellable]=[:]
    private var refreshTask:Task<Void,Never>?
    private var sharedDirty=false,sharedFingerprint=""
    private let oilSearch=OilQueryEngine(),compactSearch=SearchAccelerator()
    private var searchTask:Task<Void,Never>?,searchID=UUID()
    private var quickTask:Task<Void,Never>?,quickID=UUID()
    private var quickSnapshots:[QuickScope:NameIndex]=[:]
    private var quickWatcher:OilQuickWatcher?,quickWatchTask:Task<Void,Never>?
    private var watchedQuickRoot:String?,quickNeedsRefresh=false
    private var deepTask:Task<Void,Never>?,deepHits:[FileHit]=[],deepQuery=""
    private var stopping=false
    private var batching=false,displayLimit=200,lastRequest=""
    private let systemRecents=SystemRecents()
    private var systemOpened:[String:Date]=[:],lastRecents:Date?
    var folder:URL? {sources.first?.url}
    var indexedFileCount:Int {localEngines.values.reduce(0){$0+$1.fileCount}+(index?.files.count ?? 0)}
    var hasIndex:Bool {localEngines.values.contains {$0.hasIndex} || index != nil}
    var isIndexing:Bool {localEngines.values.contains {$0.isScanning} || sharedEngines.values.contains {$0.isIndexing}}
    var scanned:Int {localEngines.values.reduce(0){$0+$1.progress}+sharedEngines.values.reduce(0){$0+$1.scanned}}
    var scannedDirectories:Int {localEngines.values.reduce(0){$0+$1.directoryCount}+sharedEngines.values.reduce(0){$0+$1.scannedDirectories}}
    var connectionUnavailable:Bool {!localEngines.values.contains {$0.hasIndex} && !sharedEngines.isEmpty && sharedEngines.values.allSatisfy {$0.connectionUnavailable}}
    var indexSummary:String {"\(sources.count) 个搜索位置 · 已索引 \(indexedFileCount) 个文件 · Oil Find 内核"}
    var indexStatus:String {(localEngines.values.map {"\($0.root.lastPathComponent.isEmpty ? "/" : $0.root.lastPathComponent)：\($0.status)"}+sources.filter {$0.kind == .shared}.map {"\($0.url.lastPathComponent)：\(sharedEngines[$0.id]?.indexStatus ?? "等待索引")"}).joined(separator:"\n")}
    var coverage:String {"本地：FSEvents 实时更新与历史补齐；共享盘：分批检查。本地不可访问目录：\(localEngines.values.reduce(UInt64(0)){$0+$1.unreadableDirectories})。\n"+sharedEngines.values.map(\.coverage).joined(separator:"\n")}
    var hasMoreResults:Bool {hits.count < resultCount}
    init(storage:URL?=nil,policy:ScanPolicy=ScanPolicy(),tick:Duration = .seconds(2)) {
        self.storage=storage ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("com.chenhuang.smbsearch/NameIndexes",isDirectory:true)
        self.policy=policy;self.tick=tick
        try? FileManager.default.createDirectory(at:self.storage.appendingPathComponent("OilCore"),withIntermediateDirectories:true)
        if let data=try? Data(contentsOf:self.storage.appendingPathComponent("duck-preferences.json")),let value=try? JSONDecoder().decode(DuckPreferences.self,from:data) {preferences=value}
        if preferences.installDefaultBlacklist() {savePreferences()}
        if preferences.migrateColorTags() {savePreferences()}
        if let data=try? Data(contentsOf:self.storage.appendingPathComponent("automatic.json")),let value=try? JSONDecoder().decode(AutoSettings.self,from:data) {autoUpdate=value.enabled}
        if let data=try? Data(contentsOf:self.storage.appendingPathComponent("sources.json")),let value=try? JSONDecoder().decode([SearchRoot].self,from:data) {sources=value}
        else if let data=try? Data(contentsOf:self.storage.appendingPathComponent("selection.json")),let url=try? JSONDecoder().decode(URL.self,from:data) {sources=[SearchRoot(url:url,kind:url.path.hasPrefix("/Volumes/") ? .shared : .local)];saveSources()}
        let found=detectWechat();if preferences.wechatFolder != found {preferences.wechatFolder=found;savePreferences()}
        if let data=try? Data(contentsOf:self.storage.appendingPathComponent("directory-shortcuts.json")),let urls=try? JSONDecoder().decode([URL].self,from:data) {directoryShortcuts=urls}
        if let data=try? Data(contentsOf:self.storage.appendingPathComponent("search-history.json")),let values=try? JSONDecoder().decode([String].self,from:data) {searchHistory=Array(values.prefix(5))}
        configureAll()
    }
    private func detectWechat()->URL? {WechatLocations.locate(home:FileManager.default.homeDirectoryForCurrentUser,existing:preferences.wechatFolder)}
    private var scanPolicy:ScanPolicy {var value=policy;value.excludedPaths=Array(Set(policy.excludedPaths+preferences.effectiveBlacklist));return value}
    private func nativeConfig(_ root:URL)->IndexConfig {
        var config=IndexConfig.standard()
        if let path=realpath(root.path,nil) {config.rootPath=String(cString:path);free(path)}
        else {config.rootPath=root.standardizedFileURL.path}
        if config.rootPath != "/" {config.excludedPaths.removeAll {DuckRules.under(root,URL(fileURLWithPath:$0))}}
        config.userExcludedPaths=(policy.excludedPaths+preferences.effectiveBlacklist).map { url in
            guard let path=realpath(url.path,nil) else {return url.standardizedFileURL.path}
            defer {free(path)};return String(cString:path)
        }
        let options=preferences.localIndexOptions ?? LocalIndexOptions()
        config.indexSystemDirs=options.indexSystemDirs;config.indexUserLibrary=options.indexUserLibrary
        config.indexDependencyDirs=options.indexDependencyDirs;config.indexPackageContents=options.indexPackageContents
        let library=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        if DuckRules.under(root,library) {config.indexUserLibrary=true}
        return config
    }
    private func scheduleRefresh(shared:Bool) {
        guard !stopping else {return}
        sharedDirty = sharedDirty || shared
        guard refreshTask == nil else {return}
        refreshTask=Task { [weak self] in
            do {try await Task.sleep(for:.milliseconds(150))} catch {return}
            guard let self else {return};refreshTask=nil
            if sharedDirty {sharedDirty=false;rebuildShared()}
            objectWillChange.send()
            if hasIndex && status.hasPrefix("Oil Find 首次") {status=""}
            if !query.isEmpty || scopeTitle != nil || tagFilter != nil {search()}
        }
    }
    private func configureAll() {
        shutdown();subscriptions.removeAll();localEngines.removeAll();sharedEngines.removeAll();sharedFingerprint=""
        stopping=false;configureLocals()
        for source in sources where source.kind == .shared {attachShared(source)}
        rebuildShared(force:true)
    }
    private func configureLocals() {
        for (id,engine) in localEngines {subscriptions.removeValue(forKey:id);engine.stop()}
        localEngines.removeAll()
        var accepted:[(URL,IndexConfig)]=[]
        for source in sources.filter({$0.kind == .local}).sorted(by:{$0.url.path.count < $1.url.path.count}) {
            let covered=accepted.contains {parent,config in
                guard DuckRules.under(source.url,parent) else {return false}
                return Array(source.url.standardizedFileURL.path.utf8).withUnsafeBufferPointer {!config.isExcluded(path:$0)}
            }
            if covered {continue}
            let config=nativeConfig(source.url);accepted.append((source.url,config));attachLocal(source.id,root:source.url,config:config)
        }
        if let wechat=preferences.wechatFolder,accepted.contains(where:{DuckRules.under(wechat,$0.0)}) {
            let covered=accepted.contains {parent,config in DuckRules.under(wechat,parent) && Array(wechat.path.utf8).withUnsafeBufferPointer {!config.isExcluded(path:$0)} }
            if !covered {attachLocal("wechat:"+wechat.path,root:wechat,config:nativeConfig(wechat))}
        }
    }
    private func attachLocal(_ id:String,root:URL,config:IndexConfig) {
        let digest=SHA256.hash(data:Data(id.utf8)).map {String(format:"%02x",$0)}.joined()
        let engine=OilLocalEngine(id:id,root:root,config:config,database:storage.appendingPathComponent("OilCore/"+digest+".idx"),automatic:autoUpdate)
        localEngines[id]=engine
        subscriptions[id]=engine.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh(shared:false) }
        engine.onChange={ [weak self] in self?.scheduleRefresh(shared:false) }
    }
    private func attachShared(_ source:SearchRoot) {
        let engine=SearchModel(storage:storage,policy:scanPolicy,tickInterval:tick,restoreSelection:false,persistSelection:false)
        engine.autoUpdate=autoUpdate;sharedEngines[source.id]=engine
        subscriptions[source.id]=engine.objectWillChange.sink {[weak self] _ in self?.scheduleRefresh(shared:true)}
        engine.selectFolder(source.url)
    }
    private func rebuildShared(force:Bool=false) {
        let signature=sources.filter {$0.kind == .shared}.map {"\($0.id):\(sharedEngines[$0.id]?.index?.created.timeIntervalSince1970 ?? 0):\(sharedEngines[$0.id]?.index?.files.count ?? -1)"}.joined(separator:"|")
        guard force || signature != sharedFingerprint else {return};sharedFingerprint=signature
        var files:[String:FileHit]=[:],folders:[String:DirectoryRecord]=[:],found=false
        let exclusions=DuckExclusions(preferences.effectiveBlacklist)
        for engine in sharedEngines.values {
            guard let snapshot=engine.index else {continue};found=true
            folders[snapshot.root.path]=DirectoryRecord(url:snapshot.root,checked:snapshot.created,due:.distantFuture,hotUntil:nil)
            for file in snapshot.files where !exclusions.contains(file.url) {files[file.id]=file}
            for folder in SearchPresentation.folderHits(index:snapshot) where !exclusions.contains(folder.url) {folders[folder.id]=DirectoryRecord(url:folder.url,checked:snapshot.created,due:.distantFuture,hotUntil:nil,modified:folder.modified)}
        }
        index=found ? NameIndex(root:URL(fileURLWithPath:"/"),created:Date(),files:Array(files.values),directories:Array(folders.values)) : nil
    }
    func summary(_ source:SearchRoot)->String {
        if source.kind == .shared,let engine=sharedEngines[source.id] {return engine.isIndexing ? "正在索引 \(engine.scanned) 个文件" : "\(engine.index?.files.count ?? 0) 个文件"}
        if let engine=localEngines[source.id] {return "\(engine.fileCount) 个文件 · \(engine.status)"}
        return "由上级本地搜索位置覆盖"
    }
    func add(_ url:URL,kind:SourceKind) {
        let source=SearchRoot(url:url.standardizedFileURL,kind:kind)
        guard !sources.contains(where:{$0.id == source.id}) else {return}
        sources.append(source);saveSources()
        if kind == .local {configureLocals()} else {attachShared(source);rebuildShared(force:true)}
    }
    func remove(_ source:SearchRoot) {sources.removeAll {$0.id == source.id};saveSources();configureAll();search()}
    func setKind(_ source:SearchRoot,_ kind:SourceKind) {guard let i=sources.firstIndex(where:{$0.id == source.id}) else {return};sources[i].kind=kind;saveSources();configureAll();search()}
    private func saveSources() {save(sources,to:"sources.json")}
    private func saveAuto() {save(AutoSettings(enabled:autoUpdate),to:"automatic.json")}
    func savePreferences() {save(preferences,to:"duck-preferences.json")}
    private func save<T:Encodable>(_ value:T,to file:String) {do {try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:true);try JSONEncoder().encode(value).write(to:storage.appendingPathComponent(file),options:.atomic)} catch {status="设置保存失败：\(error.localizedDescription)"}}
    func cancelSearch() {searchID=UUID();searchTask?.cancel();isSearching=false}
    func clearResults() {cancelSearch();hits=[];resultCount=0;lastRequest=""}
    func loadMoreResults() {displayLimit += 200;search()}
    func updateScope() {search()}
    func search() {
        cancelSearch()
        let term=query.trimmingCharacters(in:.whitespacesAndNewlines),quick=quickScope
        let today=quick == .downloads || quick == .wechat
        if !today {quickID=UUID();quickTask?.cancel();quickWatchTask?.cancel();quickWatchTask=nil;quickWatcher?.stop();quickWatcher=nil;watchedQuickRoot=nil;quickNeedsRefresh=false;refreshingQuick=false;quickRefreshStatus=""}
        guard !term.isEmpty || scopeTitle != nil || tagFilter != nil else {status="";clearResults();return}
        guard localSelected || sharedSelected else {hits=[];resultCount=0;return}
        if today && !localSelected {hits=[];resultCount=0;return}
        let compact=quickSnapshots[quick].flatMap {Calendar.current.isDateInToday($0.created) ? $0 : nil}
        if today && compact == nil {hits=[];resultCount=0;isSearching=true;if !refreshingQuick {refreshToday(quick)};return}
        let local=localSelected ? localEngines.values.compactMap(\.handle) : []
        let shared=sharedSelected ? index : nil
        if !today && !hasIndex && quick != .recent && !(sharedSelected && deepQuery == term && !deepHits.isEmpty) {hits=[];resultCount=0;status="Oil Find 首次索引正在建立，请稍候。";return}
        status=""
        if !term.isEmpty {scheduleHistory(term)}
        let request="\(directoryScope?.path ?? "")|\(term)|\(quick.rawValue)|\(category.rawValue)|\(resultSort.rawValue)|\(localSelected)|\(sharedSelected)|\(preferences.suppressNoise)|\(tagFilter ?? "")"
        if lastRequest != request {displayLimit=200;lastRequest=request}
        let id=UUID();searchID=id;isSearching=true
        let prefs:DuckPreferences={var value=preferences;value.tagFilter=tagFilter;return value}()
        let oilSearch=oilSearch,compactSearch=compactSearch,system=systemOpened,sort=resultSort,category=category,limit=displayLimit
        let scopeRoot=directoryScope
        let downloads=FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask)[0]
        let deep=(sharedSelected && deepQuery == term) ? deepHits : []
        let deepFolders=sources.filter {$0.kind == .shared}.map {DirectoryRecord(url:$0.url,checked:Date(),due:.distantFuture,hotUntil:nil)}
        searchTask=Task {
            let worker=Task.detached(priority:.userInitiated) {
                let opened=prefs.recentOpened.merging(system,uniquingKeysWith:max)
                if today,let compact {return await compactSearch.search(index:compact,term:term,category:category,sort:sort,quick:quick,preferences:prefs,opened:opened,download:downloads,limit:limit)}
                if quick == .recent {
                    let snapshot=await oilSearch.recentSnapshot(local:local,sharedSnapshot:shared,opened:opened,preferences:prefs)
                    return await compactSearch.search(index:snapshot,term:term,category:category,sort:sort,quick:.recent,preferences:prefs,opened:opened,download:downloads,limit:limit)
                }
                var sharedSnapshot=shared
                if !deep.isEmpty {
                    var records=Dictionary((shared?.files ?? []).map {($0.id,$0)},uniquingKeysWith:{a,_ in a})
                    for file in deep {records[file.id]=file}
                    sharedSnapshot=NameIndex(root:URL(fileURLWithPath:"/"),created:Date(),files:Array(records.values),directories:shared?.directories ?? deepFolders)
                }
                return await oilSearch.search(local:local,sharedSnapshot:sharedSnapshot,term:term,category:category,sort:sort,preferences:prefs,opened:opened,limit:limit,scopeRoot:scopeRoot)
            }
            let result=await withTaskCancellationHandler {await worker.value} onCancel:{worker.cancel()}
            guard !Task.isCancelled,searchID == id else {return}
            hits=result.hits;resultCount=result.total;isSearching=false
        }
    }
    func activateQuick(_ quick:QuickScope) {
        quickTask?.cancel();quickID=UUID();refreshingQuick=false;quickRefreshStatus=""
        batching=true;directoryScope=nil;quickScope=quick;localSelected=true;sharedSelected=quick == .recent
        if quick == .recent {resultSort = .recent}
        if quick == .downloads {let root=FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask)[0];if !sources.contains(where:{$0.kind == .local && DuckRules.under(root,$0.url)}) {add(root,kind:.local)}}
        if quick == .wechat {
            let found=detectWechat();if preferences.wechatFolder != found {preferences.wechatFolder=found;quickSnapshots.removeValue(forKey:.wechat);savePreferences();configureLocals()}
            if let root=preferences.wechatFolder,!sources.contains(where:{$0.kind == .local && DuckRules.under(root,$0.url)}) {add(root,kind:.local)}
        }
        batching=false;search()
        if quick == .recent {lastRecents=nil;refreshRecents()} else if !refreshingQuick {refreshToday(quick)}
    }
    func showHome() {
        rememberSearch(query);historyTask?.cancel();historyTask=nil;historyCandidate=""
        batching=true;query="";tagFilter=nil;category = .all;directoryScope=nil;quickScope = .none;localSelected=true;sharedSelected=true;batching=false
        status="";deepStatus="";search()
    }
    func rememberSearch(_ value:String) {
        let term=value.trimmingCharacters(in:.whitespacesAndNewlines);guard !term.isEmpty else {return}
        var values=searchHistory.filter {$0.caseInsensitiveCompare(term) != .orderedSame};values.insert(term,at:0);values=Array(values.prefix(5))
        guard values != searchHistory else {return};searchHistory=values;save(values,to:"search-history.json")
    }
    private func scheduleHistory(_ term:String) {
        guard historyCandidate != term else {return};historyTask?.cancel();historyCandidate=term
        historyTask=Task { [weak self] in
            do {try await Task.sleep(for:.milliseconds(900))} catch {return}
            guard let self,!stopping,query.trimmingCharacters(in:.whitespacesAndNewlines) == term else {return}
            rememberSearch(term)
        }
    }
    func recallSearch(_ term:String) {query=term;rememberSearch(term);search()}
    func clearSearchHistory() {historyTask?.cancel();historyTask=nil;historyCandidate=query.trimmingCharacters(in:.whitespacesAndNewlines);searchHistory=[];save(searchHistory,to:"search-history.json")}
    func clearScope() {
        batching=true;directoryScope=nil;quickScope = .none;localSelected=true;sharedSelected=true;batching=false;search()
    }
    func activateShared() {
        batching=true;directoryScope=nil;quickScope = .none;localSelected=false;sharedSelected=true;batching=false;search();for engine in sharedEngines.values {engine.requestUserRefresh()}
    }
    func activateDirectory(_ url:URL) {
        batching=true;directoryScope=url.standardizedFileURL;quickScope = .none;localSelected=true;sharedSelected=true;batching=false;search()
    }
    func addDirectoryShortcut(_ url:URL,kind:SourceKind) {
        let normalized=url.standardizedFileURL
        if !directoryShortcuts.contains(normalized) {directoryShortcuts.append(normalized);save(directoryShortcuts,to:"directory-shortcuts.json")}
        let covered=sources.contains {$0.kind == kind && DuckRules.under(normalized,$0.url)}
        if !covered {add(normalized,kind:kind)}
        else if kind == .local {
            let config=nativeConfig(sources.first {$0.kind == .local && DuckRules.under(normalized,$0.url)}!.url)
            let excluded=Array(normalized.path.utf8).withUnsafeBufferPointer {config.isExcluded(path:$0)}
            if excluded {add(normalized,kind:.local)}
        }
        activateDirectory(normalized)
    }
    func removeDirectoryShortcut(_ url:URL) {
        let normalized=url.standardizedFileURL
        directoryShortcuts.removeAll {$0 == normalized};save(directoryShortcuts,to:"directory-shortcuts.json")
        if directoryScope == normalized {clearScope()}
    }
    func chooseDirectoryShortcut() {
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
        panel.message="选择要添加到搜索入口的目录";panel.prompt="增加目录"
        if panel.runModal() == .OK,let url=panel.url {
            let local=(try? url.resourceValues(forKeys:[.volumeIsLocalKey]).volumeIsLocal) ?? true
            addDirectoryShortcut(url,kind:local ? .local : .shared)
        }
    }
    private func refreshToday(_ quick:QuickScope) {
        quickTask?.cancel();let id=UUID();quickID=id
        let root=quick == .downloads ? FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask)[0] : preferences.wechatFolder
        guard let root else {isSearching=false;refreshingQuick=false;quickRefreshStatus="未检测到微信接收目录，请先在微信接收文件后再试。";return}
        if watchedQuickRoot != root.path {
            quickWatcher?.stop();watchedQuickRoot=root.path
            quickWatcher=OilQuickWatcher(root:root) { [weak self] in self?.scheduleQuickRefresh() }
        }
        var policy=scanPolicy;policy.fullScanPause = .zero;policy.localScope=LocalIndexScope(options:preferences.localIndexOptions ?? LocalIndexOptions(),wechat:preferences.wechatFolder)
        let value=policy
        refreshingQuick=true;quickRefreshStatus="正在补查今天的文件…"
        quickTask=Task {
            let worker=Task.detached(priority:.userInitiated) {try await TodayQuickScanner.scan(quick:quick,root:root,policy:value)}
            do {
                let result=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
                guard !Task.isCancelled,quickID == id,quickScope == quick else {return}
                quickSnapshots[quick]=NameIndex(root:root,created:Date(),files:result.files,directories:[])
                refreshingQuick=false;quickRefreshStatus=result.warning.isEmpty ? "已补查最新文件" : result.warning;search()
                if quickNeedsRefresh {quickNeedsRefresh=false;refreshToday(quick)}
            } catch {
                guard !Task.isCancelled,quickID == id else {return}
                refreshingQuick=false;isSearching=false;quickRefreshStatus="读取目录失败：\(error.localizedDescription)"
            }
        }
    }
    private func scheduleQuickRefresh() {
        guard !stopping else {return}
        guard quickScope == .downloads || quickScope == .wechat else {return}
        if refreshingQuick {quickNeedsRefresh=true;return}
        guard quickWatchTask == nil else {return}
        quickWatchTask=Task { [weak self] in
            do {try await Task.sleep(for:.milliseconds(200))} catch {return}
            guard let self else {return};quickWatchTask=nil
            if quickScope == .downloads || quickScope == .wechat {refreshToday(quickScope)}
        }
    }
    func refreshRecents() {
        guard lastRecents.map({Date().timeIntervalSince($0)>=30}) ?? true else {return}
        let roots=sources.filter {$0.kind == .local}.map(\.url);guard !roots.isEmpty else {return};lastRecents=Date()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for:.milliseconds(300))
            self?.systemRecents.load(scopes:roots) { [weak self] opened in self?.systemOpened=opened;if self?.resultSort == .recent {self?.search()} }
        }
    }
    func buildIndex() {for engine in localEngines.values {engine.rebuild()};for engine in sharedEngines.values {engine.buildIndex()}}
    func cancelIndex() {for engine in localEngines.values {engine.cancelScan()};for engine in sharedEngines.values {engine.cancelIndex()}}
    func shutdown() {rememberSearch(query);stopping=true;historyTask?.cancel();historyCandidate="";refreshTask?.cancel();refreshTask=nil;quickWatcher?.stop();quickWatcher=nil;watchedQuickRoot=nil;quickWatchTask?.cancel();quickWatchTask=nil;quickTask?.cancel();quickID=UUID();refreshingQuick=false;quickNeedsRefresh=false;for engine in localEngines.values {engine.stop()};for engine in sharedEngines.values {engine.autoUpdate=false;engine.cancelIndex()}}
    func setLocalOptions(_ options:LocalIndexOptions) {preferences.localIndexOptions=options;savePreferences();configureLocals();search()}
    func toggleNoise(_ enabled:Bool) {preferences.suppressNoise=enabled;savePreferences();search()}
    func addBlacklist(_ url:URL,developer:Bool=false) {
        let path=url.standardizedFileURL
        if developer {var list=preferences.developerBlacklist ?? [];guard !list.contains(path) else {return};list.append(path);preferences.developerBlacklist=list}
        else {guard !preferences.blacklist.contains(path) else {return};preferences.blacklist.append(path)}
        savePreferences();quickSnapshots.removeAll();configureAll();search()
    }
    func removeBlacklist(_ url:URL,developer:Bool=false) {if developer {preferences.developerBlacklist?.removeAll {$0 == url}} else {preferences.blacklist.removeAll {$0 == url}};savePreferences();quickSnapshots.removeAll();configureAll();search()}
    func chooseBlacklist(developer:Bool=false) {let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;if panel.runModal() == .OK,let url=panel.url {addBlacklist(url,developer:developer)}}
    func diskAuthorization() {NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!);status="请在完全磁盘访问权限中开启应用程序里的找鸭，然后重启。"}
    func chooseAuthorizedDisk() {chooseFolder(kind:.local)}
    func chooseFolder(kind:SourceKind) {let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=true;panel.directoryURL=URL(fileURLWithPath:kind == .local ? "/" : "/Volumes");if panel.runModal() == .OK {for url in panel.urls {add(url,kind:kind)}}}
    func deepSearch() {
        if deepSearching {deepTask?.cancel();return}
        let term=query.trimmingCharacters(in:.whitespacesAndNewlines),roots=sources.filter {$0.kind == .shared}.compactMap {source -> URL? in
            guard let scope=directoryScope else {return source.url}
            if DuckRules.under(scope,source.url) {return scope}
            return DuckRules.under(source.url,scope) ? source.url : nil
        }
        guard !term.isEmpty else {deepStatus="请先输入关键词。";return};guard !roots.isEmpty else {deepStatus="请先添加共享盘。";return}
        quickScope = .none;localSelected=false;sharedSelected=true;deepSearching=true;deepStatus="正在深度搜索共享盘…";deepQuery=term;deepHits=[]
        let policy=scanPolicy
        deepTask=Task {let worker=Task.detached {DuckDeepSearch.run(roots:roots,term:term,policy:policy)};let result=await withTaskCancellationHandler {await worker.value} onCancel:{worker.cancel()};deepSearching=false;guard !Task.isCancelled else {deepStatus="已停止深度搜索";return};deepHits=result.0;deepStatus="找到 \(deepHits.count) 个文件"+(result.1.isEmpty ? "" : "；部分目录无法读取");sharedSelected=true;search()}
    }
    var tagCatalog:[FileTag] {FileTag.defaults+(preferences.customTags ?? [])}
    func tags(_ file:FileHit)->[FileTag] {let ids=preferences.fileTags?[file.id] ?? [];return tagCatalog.filter {ids.contains($0.id)}}
    func hasTag(_ file:FileHit,_ tag:FileTag)->Bool {preferences.fileTags?[file.id]?.contains(tag.id) == true}
    func toggleTag(_ file:FileHit,_ tag:FileTag) {setTag(file,tag,enabled:!hasTag(file,tag))}
    func setTag(_ file:FileHit,_ tag:FileTag,enabled:Bool) {
        var mapping=preferences.fileTags ?? [:],ids=mapping[file.id] ?? []
        if enabled {ids.insert(tag.id)} else {ids.remove(tag.id)}
        mapping[file.id]=ids.isEmpty ? nil : ids;preferences.fileTags=mapping;savePreferences();search()
    }
    func clearTags(_ file:FileHit) {preferences.fileTags?.removeValue(forKey:file.id);savePreferences();search()}
    @discardableResult func createTag(name:String,color:FileMarkColor,applyTo file:FileHit)->FileTag? {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines);guard !name.isEmpty else {return nil}
        let tag=(preferences.customTags ?? []).first {$0.name.caseInsensitiveCompare(name) == .orderedSame && $0.color == color} ?? FileTag(id:UUID().uuidString,name:name,color:color)
        if !(preferences.customTags ?? []).contains(where:{$0.id == tag.id}) {var custom=preferences.customTags ?? [];custom.append(tag);preferences.customTags=custom}
        setTag(file,tag,enabled:true);return tag
    }
    func updateTag(_ tag:FileTag,name:String,color:FileMarkColor) {
        guard let i=preferences.customTags?.firstIndex(where:{$0.id == tag.id}) else {return}
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines);guard !name.isEmpty else {return}
        preferences.customTags?[i].name=name;preferences.customTags?[i].color=color;savePreferences();search()
    }
    func deleteTag(_ tag:FileTag) {
        preferences.customTags?.removeAll {$0.id == tag.id}
        for path in Array(preferences.fileTags?.keys ?? Dictionary<String,Set<String>>().keys) {preferences.fileTags?[path]?.remove(tag.id)}
        if tagFilter == tag.id {tagFilter=nil};savePreferences();search()
    }
    func blockFile(_ file:FileHit) {var paths=preferences.blockedFiles ?? [];paths.insert(file.id);preferences.blockedFiles=paths;savePreferences();search()}
    func unblockFile(_ path:String) {preferences.blockedFiles?.remove(path);savePreferences();search()}
    func setNote(_ text:String,file:FileHit) {var notes=preferences.fileNotes ?? [:];let text=text.trimmingCharacters(in:.whitespacesAndNewlines);notes[file.id]=text.isEmpty ? nil : text;preferences.fileNotes=notes;savePreferences();search()}
    func chooseNote(_ file:FileHit) {
        let alert=NSAlert();alert.messageText="文件备注";alert.informativeText="仅用于当前文件，留空可移除备注。";alert.addButton(withTitle:"保存");alert.addButton(withTitle:"取消")
        let field=NSTextField(frame:NSRect(x:0,y:0,width:340,height:28));field.stringValue=preferences.fileNotes?[file.id] ?? "";field.setAccessibilityLabel("文件备注");alert.accessoryView=field;alert.window.initialFirstResponder=field
        if alert.runModal() == .alertFirstButtonReturn {setNote(field.stringValue,file:file)}
    }
    func chooseEditTag(_ tag:FileTag) {
        let alert=NSAlert();alert.messageText="编辑标签";alert.addButton(withTitle:"保存");alert.addButton(withTitle:"取消")
        let view=NSView(frame:NSRect(x:0,y:0,width:280,height:92)),field=NSTextField(frame:NSRect(x:10,y:54,width:260,height:26));field.stringValue=tag.name;field.setAccessibilityLabel("标签文字")
        var color=tag.color;let palette=TagColorPalette(selected:{[color]},toggle:{color=$0});palette.frame=NSRect(x:0,y:4,width:280,height:42);view.addSubview(field);view.addSubview(palette);alert.accessoryView=view;alert.window.initialFirstResponder=field
        if alert.runModal() == .alertFirstButtonReturn {updateTag(tag,name:field.stringValue,color:color)}
    }
    func chooseCustomTag(_ file:FileHit) {
        let alert=NSAlert();alert.messageText="自定义标签";alert.informativeText="填写文字并选择颜色。创建后会应用到当前文件，也可用于其他文件。"
        alert.addButton(withTitle:"创建并添加");alert.addButton(withTitle:"取消")
        let view=NSView(frame:NSRect(x:0,y:0,width:280,height:92)),field=NSTextField(frame:NSRect(x:10,y:54,width:260,height:26))
        field.placeholderString="标签文字";field.setAccessibilityLabel("标签文字")
        var color=FileMarkColor.blue
        let palette=TagColorPalette(selected:{[color]},toggle:{color=$0});palette.frame=NSRect(x:0,y:4,width:280,height:42)
        view.addSubview(field);view.addSubview(palette);alert.accessoryView=view;alert.window.initialFirstResponder=field
        if alert.runModal() == .alertFirstButtonReturn {if createTag(name:field.stringValue,color:color,applyTo:file) == nil {status="标签文字不能为空。"}}
    }
    func consumeEscape()->Bool {
        if !query.isEmpty {rememberSearch(query);query="";search();return true}
        if scopeTitle != nil {clearScope();return true}
        if tagFilter != nil {tagFilter=nil;return true}
        return false
    }
    func requestTrash(_ file:FileHit) {
        let alert=NSAlert();alert.messageText="将“\(file.name)”移到废纸篓？"
        alert.informativeText="可以从废纸篓恢复。若所在磁盘不支持废纸篓，本次操作将失败。"
        alert.alertStyle = .warning;alert.addButton(withTitle:"移到废纸篓");alert.addButton(withTitle:"取消")
        if alert.runModal() == .alertFirstButtonReturn {Task {await trash(file)}}
    }
    func trash(_ file:FileHit) async {
        do {
            try await Task.detached(priority:.userInitiated) {try FileOperations.trash(file.url)}.value
            hits.removeAll {DuckRules.under($0.url,file.url)};resultCount=max(hits.count,resultCount-1)
            for key in Array(quickSnapshots.keys) {if let snapshot=quickSnapshots[key] {quickSnapshots[key]=NameIndex(root:snapshot.root,created:snapshot.created,files:snapshot.files.filter {!DuckRules.under($0.url,file.url)},directories:snapshot.directories)}}
            preferences.fileNotes?.removeValue(forKey:file.id);preferences.fileTags?.removeValue(forKey:file.id);preferences.colorMarks?.removeValue(forKey:file.id);preferences.recentOpened.removeValue(forKey:file.id)
            savePreferences();status="已移到废纸篓：\(file.name)"
        } catch {status="无法移到废纸篓：\(error.localizedDescription)"}
    }
    func open(_ file:FileHit) {action(file,reveal:false)}
    func reveal(_ file:FileHit) {action(file,reveal:true)}
    private func action(_ file:FileHit,reveal:Bool) {rememberSearch(query);Task {let exists=await Task.detached {FileManager.default.fileExists(atPath:file.url.path)}.value;guard exists else {status="文件当前不可用，请检查磁盘或共享盘连接。";return};if reveal {NSWorkspace.shared.activateFileViewerSelecting([file.url])} else if NSWorkspace.shared.open(file.url) {preferences.recentOpened[file.id]=Date();savePreferences();if resultSort == .recent {search()}}}}
}
