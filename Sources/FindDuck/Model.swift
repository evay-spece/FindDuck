import SwiftUI
import AppKit
import CryptoKit

struct AutoSettings: Codable { let enabled: Bool }

@MainActor final class SearchModel: ObservableObject {
    @Published var smbAddress = ""
    @Published var connectionMessage = "填写 SMB 地址连接，或选择已挂载的共享文件夹。"
    @Published var folder: URL?
    @Published var query = ""
    @Published var hits: [FileHit] = []
    @Published var category: ResultCategory = .all { didSet { if !lastSearchTerm.isEmpty { performSearch(lastSearchTerm) } } }
    @Published var resultSort: ResultSort = .relevance { didSet { if !lastSearchTerm.isEmpty { performSearch(lastSearchTerm) } } }
    var connectionUnavailable: Bool { lastAvailable == false }
    @Published var status = "选择共享文件夹后，将自动建立文件名索引。"
    @Published var indexStatus = ""
    @Published var coverage = ""
    @Published var isIndexing = false
    @Published var isSearching = false
    @Published var isChecking = false
    @Published var index: NameIndex? { didSet { folderHits = index.map { SearchPresentation.folderHits(index: $0) } ?? [] } }
    private var folderHits: [FileHit] = []
    @Published var scanned = 0
    @Published var scannedDirectories = 0
    @Published var autoUpdate = true {
        didSet {
            guard autoUpdate != oldValue else { return }
            saveSettings()
            if autoUpdate {
                lastAvailable = nil
                retryFullAfter = .distantPast
                updateHints()
                Task { [weak self] in await self?.automaticTick() }
            } else {
                hints.stop()
                if automaticBuild { cancelIndex() }
            }
        }
    }
    private let storage: URL
    private let persistSelection: Bool
    private let policy: ScanPolicy
    private let tickInterval: Duration
    private let availabilityInterval: TimeInterval
    private let batchLimit: Int
    private let notificationLimit: Int
    private let hints = DirectoryHints()
    private var catalog: IndexCatalog?
    private var dirty = Set<String>()
    private var unreadable = Set<String>()
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var indexID = UUID(), searchID = UUID(), scopeID = UUID(), checkID = UUID()
    private var lastAvailable: Bool?
    private var lastProbe = Date.distantPast
    private var lastTick = Date()
    private var lastSaved = Date()
    private var retryFullAfter = Date.distantPast
    private var automaticBuild = false
    private var lastSearchTerm = ""
    private var needsBaseline = false
    var hasIndex: Bool { index != nil }
    var directoryCount: Int { catalog?.records.count ?? 0 }
    var indexSummary: String {
        guard let index else { return "尚未建立索引" }
        return "已索引 \(index.files.count) 个文件 · 索引变更于 \(index.created.formatted(date: .numeric, time: .shortened))"
    }
    init(storage: URL? = nil, policy: ScanPolicy = ScanPolicy(), tickInterval: Duration = .seconds(2), availabilityInterval: TimeInterval = 30, batchLimit: Int = 2, notificationLimit: Int = 64, restoreSelection: Bool = true, persistSelection: Bool = true) {
        self.storage = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.chenhuang.smbsearch/NameIndexes", isDirectory: true)
        self.persistSelection = persistSelection
        self.policy = policy
        self.tickInterval = tickInterval
        self.availabilityInterval = availabilityInterval
        self.batchLimit = batchLimit
        self.notificationLimit = notificationLimit
        if let data = try? Data(contentsOf: self.storage.appendingPathComponent("automatic.json")),
           let settings = try? JSONDecoder().decode(AutoSettings.self, from: data) { autoUpdate = settings.enabled }
        if restoreSelection, let data = try? Data(contentsOf: self.storage.appendingPathComponent("selection.json")),
           let root = try? JSONDecoder().decode(URL.self, from: data) { selectFolder(root) }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.automaticTick()
                do { try await Task.sleep(for: tickInterval) } catch { return }
            }
        }
    }
    deinit { monitorTask?.cancel(); indexTask?.cancel(); searchTask?.cancel(); hints.stop() }
    private func saveSettings() {
        guard persistSelection else { return }
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try JSONEncoder().encode(AutoSettings(enabled: autoUpdate)).write(to: storage.appendingPathComponent("automatic.json"), options: .atomic)
        } catch { indexStatus = "自动更新设置未能保存：\(error.localizedDescription)" }
    }
    private func indexURL(_ root: URL) -> URL {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return storage.appendingPathComponent(digest + ".json")
    }
    private func persist(_ snapshot: NameIndex) throws {
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: indexURL(snapshot.root), options: .atomic)
        lastSaved = Date()
    }
    func connect() {
        let raw = smbAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { connectionMessage = "请输入 SMB 地址，例如 smb://服务器/共享名称"; return }
        let address = raw.lowercased().hasPrefix("smb://") ? raw : "smb://" + raw
        guard let url = URL(string: address), url.host != nil, url.user == nil, url.password == nil else { connectionMessage = "请输入不含账户密码的 SMB 地址，登录由 macOS 处理。"; return }
        NSWorkspace.shared.open(url)
        connectionMessage = "已请求 macOS 连接。首次使用请在登录后选择共享文件夹。"
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择要建立文件名索引的共享文件夹"
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        if panel.runModal() == .OK, let root = panel.url { selectFolder(root) }
    }
    func selectFolder(_ root: URL) {
        cancelIndex(); cancelSearch(); hints.stop()
        scopeID = UUID(); checkID = UUID(); isChecking = false
        folder = root.standardizedFileURL
        hits = []; index = nil; catalog = nil
        lastSearchTerm = ""; lastAvailable = nil
        lastProbe = .distantPast; retryFullAfter = .distantPast
        dirty = []; unreadable = []; coverage = ""; indexStatus = ""
        needsBaseline = true
        let cache = indexURL(root)
        if FileManager.default.fileExists(atPath: cache.path) {
            do {
                let loaded = try JSONDecoder().decode(NameIndex.self, from: Data(contentsOf: cache))
                // Remove excluded records before scheduling incremental checks on older caches.
                let exclusions=DuckExclusions(policy.excludedPaths)
                let scope=policy.localScope
                let packages=(loaded.directories ?? []).filter { !exclusions.contains($0.url) && scope?.excludes($0.url,isDirectory:true) != true && scope?.stopsAtPackage($0.url) == true }.map { FileHit(url:$0.url,modified:$0.modified) }
                let saved = NameIndex(root: loaded.root, created: loaded.created,
                    files: loaded.files.filter { !exclusions.contains($0.url) && scope?.excludes($0.url,isDirectory:$0.isDirectory) != true } + packages,
                    directories: loaded.directories?.filter { $0.url == loaded.root || (!exclusions.contains($0.url) && scope?.excludes($0.url,isDirectory:true) != true && scope?.stopsAtPackage($0.url) != true) },
                    metadataVersion: loaded.metadataVersion,
                    unreadablePaths: loaded.unreadablePaths?.filter { !exclusions.contains(URL(fileURLWithPath: $0)) && scope?.excludes(URL(fileURLWithPath:$0),isDirectory:true) != true }, scanConfiguration: loaded.scanConfiguration)
                guard saved.root.standardizedFileURL == root.standardizedFileURL else { throw IndexFailure(message: "索引目录不匹配") }
                index = saved
                catalog = IndexCatalog(saved)
                lastSaved=Date()
                needsBaseline = saved.directories?.isEmpty != false || saved.metadataVersion != 1 || saved.scanConfiguration != scope?.fingerprint
                status = "已载入本地索引，可以搜索。"
                refreshCoverage()
            } catch { status = "本地索引无法读取，需要重新建立索引。" }
        } else { status = autoUpdate ? "已选择文件夹，准备建立索引。" : "请点击“建立文件名索引”。" }
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            if persistSelection { try JSONEncoder().encode(folder).write(to: storage.appendingPathComponent("selection.json"), options: .atomic) }
        } catch { indexStatus = "下次启动需重新选择此文件夹。" }
        updateHints()
        Task { [weak self] in await self?.automaticTick() }
    }
    private func updateHints() {
        guard autoUpdate, let catalog, !needsBaseline, lastAvailable != false else { hints.stop(); return }
        let scope = scopeID
        hints.replace(catalog.watchCandidates(limit: notificationLimit)) { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self, self.autoUpdate, self.scopeID == scope, self.catalog?.records[path] != nil else { return }
                self.dirty.insert(path)
            }
        }
    }
    private func refreshCoverage() {
        guard let catalog else { coverage = ""; return }
        if needsBaseline {
            coverage = "旧版索引可继续搜索，待连接后补充目录检查信息。"
            return
        }
        let due = catalog.records.values.filter { $0.due <= Date() || dirty.contains($0.url.path) }.count
        let unseen = catalog.records.values.filter { $0.checked == nil }.count
        coverage = "共 \(catalog.records.count) 个目录 · 待检查 \(due) 个"
        if unseen > 0 { coverage += "（其中新发现 \(unseen) 个）" }
        if let oldest = catalog.records.values.compactMap(\.checked).min() {
            coverage += " · 最早目录核对于 \(oldest.formatted(date: .omitted, time: .shortened))"
        }
    }
    func requestUserRefresh() {catalog?.markAllDue(Date());Task {await automaticTick()}}
    func automaticTick() async {
        guard autoUpdate, let folder, !isIndexing, !isChecking else { return }
        isChecking = true
        let check = UUID(); checkID = check
        let scope = scopeID
        let baseline = indexID
        defer { if checkID == check { isChecking = false } }
        let now = Date()
        // After sleep, resume low-rate reconciliation instead of a burst full scan.
        if now.timeIntervalSince(lastTick) > 60 { catalog?.markAllDue(now) }
        lastTick = now
        if now.timeIntervalSince(lastProbe) >= availabilityInterval || lastAvailable == nil {
            if lastAvailable == nil { indexStatus = hasIndex ? "正在检查共享盘连接，已有索引仍可搜索…" : "正在检查文件夹连接…" }
            let available = await Task.detached(priority: .utility) { DirectoryReader.available(folder) }.value
            guard scope == scopeID, indexID == baseline, autoUpdate, !isIndexing else { return }
            lastProbe = Date()
            let previous = lastAvailable
            lastAvailable = available
            guard available else {
                hints.stop()
                indexStatus = hasIndex ? "共享盘暂不可用，已有索引仍可搜索；重连后分批补查。" : "等待共享盘连接。"
                return
            }
            if previous != true {
                catalog?.markAllDue(Date())
                if !needsBaseline { indexStatus = "已连接，正在分批核对目录。" }
                updateHints()
            }
        }
        guard lastAvailable == true else { return }
        if needsBaseline {
            if Date() >= retryFullAfter { buildIndex(automatically: true) }
            return
        }
        guard let current = catalog else { return }
        let batch = current.batch(now: Date(), dirty: dirty, limit: batchLimit).filter { !DuckRules.excluded($0, paths: policy.excludedPaths) }
        guard !batch.isEmpty else { refreshCoverage(); return }
        let policy = policy
        let results = await Task.detached(priority: .utility) {
            batch.map { url -> ListingResult in
                do { return ListingResult(url: url, listing: try DirectoryReader.read(url, policy: policy), error: nil) }
                catch { return ListingResult(url: url, listing: nil, error: error.localizedDescription) }
            }
        }.value
        guard scope == scopeID, indexID == baseline, autoUpdate, !isIndexing else { return }
        var changed = false
        for result in results {
            dirty.remove(result.url.path)
            if let listing = result.listing {
                let updated = catalog?.apply(listing, now: Date(), policy: policy) ?? false
                changed = changed || updated
                unreadable.remove(result.url.path)
            } else {
                unreadable.insert(result.url.path)
                catalog?.retry(result.url, now: Date(), policy: policy)
            }
        }
        unreadable = unreadable.filter { catalog?.records[$0] != nil }
        refreshCoverage()
        if changed || Date().timeIntervalSince(lastSaved) > 300 {
            if let current=catalog {
                do {
                    let prepared=try await Task.detached(priority:.utility) {
                        let snapshot=current.snapshot()
                        return (snapshot,try JSONEncoder().encode(snapshot))
                    }.value
                    guard scope == scopeID, indexID == baseline, autoUpdate, !isIndexing else {return}
                    let snapshot=prepared.0
                    try prepared.1.write(to:indexURL(snapshot.root),options:.atomic);lastSaved=Date()
                    let searchChanged = index?.files != snapshot.files
                    index = snapshot
                    if searchChanged {
                        if !unreadable.isEmpty { indexStatus += " 另有\(unreadable.count)个目录未能读取，请检查权限；结果可能不完整。" }
                if !lastSearchTerm.isEmpty { performSearch(lastSearchTerm) }
                        updateHints()
                    }
                } catch { lastSaved = .distantPast; indexStatus = "本地索引保存失败：\(error.localizedDescription)"; return }
            }
        }
        if unreadable.isEmpty {
            indexStatus = changed ? "已自动收录文件变化，搜索结果已刷新。" : "后台分批检查中；未发现变化的目录会降低检查频率。"
        } else {
            indexStatus = "\(unreadable.count) 个目录暂无法读取，原记录已保留并将重试；结果可能滞后。"
        }
    }
    func buildIndex(automatically: Bool = false) {
        guard let folder else { indexStatus = "请先选择共享文件夹"; return }
        guard !isIndexing else { return }
        let currentID = UUID()
        indexID = currentID
        isIndexing = true; automaticBuild = automatically
        scanned = 0; scannedDirectories = 0
        hints.stop()
        indexStatus = hasIndex ? "正在完整核对文件名；仍可搜索已有索引…" : "正在首次建立文件名索引…"
        let policy = policy
        indexTask = Task { [self] in
            let worker = Task.detached(priority: .utility) {
                try await DirectoryReader.full(folder, policy: policy) { count, directories in
                    Task { @MainActor [weak self] in
                        guard let self, self.indexID == currentID, self.isIndexing else { return }
                        self.scanned = count; self.scannedDirectories = directories
                    }
                }
            }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, indexID == currentID else { return }
                let prepared=try await Task.detached(priority:.utility) { (IndexCatalog(result),try JSONEncoder().encode(result)) }.value
                guard !Task.isCancelled, indexID == currentID else {return}
                try prepared.1.write(to:indexURL(result.root),options:.atomic);lastSaved=Date()
                index = result; catalog = prepared.0
                needsBaseline = false; unreadable = Set(result.unreadablePaths ?? []); dirty = []
                scanned = result.files.count; scannedDirectories = result.directories?.count ?? 0
                isIndexing = false; lastAvailable = true; lastProbe = Date(); lastTick = Date()
                indexStatus = "完整核对完成：\(result.files.count) 个文件、\(scannedDirectories) 个目录。"
                if !unreadable.isEmpty { indexStatus += " 另有\(unreadable.count)个目录未能读取，请检查权限；结果可能不完整。" }
                if !lastSearchTerm.isEmpty { performSearch(lastSearchTerm) }
                else { status = "可以搜索文件名。" }
                refreshCoverage(); updateHints()
            } catch {
                guard indexID == currentID else { return }
                isIndexing = false
                retryFullAfter = Date().addingTimeInterval(policy.retryInterval)
                indexStatus = "建立索引失败：\(error.localizedDescription)"
                if hasIndex { indexStatus += "；已有索引已保留。" }
                updateHints()
            }
        }
    }
    func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { status = "请输入文件名关键词"; return }
        guard hasIndex else { status = isIndexing ? "首次索引正在建立，请稍候。" : "请先建立文件名索引"; return }
        lastSearchTerm = term
        performSearch(term)
    }
    private func performSearch(_ term: String) {
        guard let index else { return }
        cancelSearch()
        let currentID = UUID(); searchID = currentID
        isSearching = true
        searchTask = Task { [self] in
            let category = category, sort = resultSort, folders = folderHits
            let worker = Task.detached(priority: .userInitiated) {
                SearchPresentation.matches(index: index, term: term, category: category, sort: sort, folders: folders)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, searchID == currentID else { return }
            hits = result; isSearching = false
            status = "找到 \(result.count) 个文件（来自本地索引）"
        }
    }
    func cancelIndex() {
        indexID = UUID(); indexTask?.cancel()
        let wasIndexing = isIndexing
        isIndexing = false; automaticBuild = false
        retryFullAfter = .distantFuture
        if wasIndexing { indexStatus = hasIndex ? "已停止完整核对，已有索引已保留。" : "已停止建立索引。" }
        updateHints()
    }
    func cancelSearch() { searchID = UUID(); searchTask?.cancel(); isSearching = false }
    func clearResults() { cancelSearch(); lastSearchTerm = ""; hits = []; status = "" }
    func open(_ file: FileHit) {
        Task {
            let exists = await Task.detached(priority: .utility) { FileManager.default.fileExists(atPath: file.url.path) }.value
            guard exists else { status = "文件当前不可用，请检查共享盘连接或等待目录更新。"; return }
            if !NSWorkspace.shared.open(file.url) { status = "无法打开文件，请检查默认打开方式。" }
        }
    }
    func reveal(_ file: FileHit) {
        Task {
            let exists = await Task.detached(priority: .utility) { FileManager.default.fileExists(atPath: file.url.path) }.value
            guard exists else { status = "文件当前不可用，请检查连接；文件变化将在目录检查后更新。"; return }
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
        }
    }
}
