import Foundation
import Darwin
import Combine
@preconcurrency import OilFindCore

final class OilManagerBox: @unchecked Sendable {
    let manager:IndexManager
    init(_ manager:IndexManager) {self.manager=manager}
}
final class OilStoreHandle: @unchecked Sendable {
    let id:String
    let store:IndexStore
    let hiddenEntryIDs:Set<UInt32>
    init(id:String,store:IndexStore,hiddenEntryIDs:Set<UInt32> = []) {self.id=id;self.store=store;self.hiddenEntryIDs=hiddenEntryIDs}
}
@MainActor final class OilLocalEngine: ObservableObject {
    let root:URL
    let id:String
    let box:OilManagerBox
    private(set) var automatic:Bool
    @Published private(set) var fileCount=0
    @Published private(set) var directoryCount=0
    @Published private(set) var progress=0
    @Published private(set) var unreadableDirectories:UInt64=0
    @Published private(set) var isScanning=false
    @Published private(set) var status="正在载入 Oil Find 索引…"
    var onChange:(()->Void)?
    private var polling:Task<Void,Never>?
    private var manualPausedScan=false
    private var pausedByUser=false
    init(id:String,root:URL,config:IndexConfig,database:URL,automatic:Bool) {
        self.id=id;self.root=root;self.automatic=automatic
        let manager=IndexManager(config:config,dbURL:database,settingsDefaults:nil)
        box=OilManagerBox(manager)
        manager.onStateChange={ [weak self] _ in Task { @MainActor in self?.update() } }
        manager.onIndexChange={ [weak self] in Task { @MainActor in self?.update();self?.onChange?() } }
        polling=Task { [weak self] in
            while !Task.isCancelled {
                self?.updateProgress()
                do {try await Task.sleep(for:.milliseconds(250))} catch {return}
            }
        }
        if automatic {manager.start()} else {manager.startOffline()}
    }
    deinit {polling?.cancel();box.manager.stop()}
    var hasIndex:Bool {box.manager.store != nil}
    var handle:OilStoreHandle? {box.manager.store.map {OilStoreHandle(id:id,store:$0)}}
    var replayedEvents:Int {box.manager.replayedEventCount}
    private func updateProgress() {
        let scanning=box.manager.state == .scanning || box.manager.isRescanning
        let count=box.manager.scannedCount
        if isScanning != scanning {isScanning=scanning}
        if scanning && progress != count {progress=count}
    }
    private func update() {
        updateProgress()
        if let store=box.manager.store {
            let counts=store.read { () -> (Int,Int,UInt64) in
                var files=0,dirs=0
                for i in 1..<store.count where store.isLive(UInt32(i)) {
                    if store.flags[i] & SiftFlag.dir != 0 && store.flags[i] & SiftFlag.package == 0 {dirs += 1} else {files += 1}
                }
                return (files,dirs,store.coverage[.noAccess].count)
            }
            fileCount=counts.0;directoryCount=counts.1;unreadableDirectories=counts.2
        }
        switch box.manager.state {
        case .idle:status=hasIndex ? "索引已保留" : "尚未建立 Oil Find 索引"
        case .loading:status="正在载入索引并补齐文件事件…"
        case .scanning:status="正在建立 Oil Find 文件名索引…"
        case .ready:status=pausedByUser ? "已暂停更新 · 使用已保存索引" : automatic ? "实时更新中 · 已补齐 \(replayedEvents) 条事件" : "使用已保存索引 · 自动更新已关闭"
        }
        if manualPausedScan && box.manager.state == .ready && !box.manager.isRescanning {
            manualPausedScan=false;box.manager.stop();box.manager.startOffline()
        }
    }
    func setAutomatic(_ enabled:Bool) {
        guard automatic != enabled || pausedByUser else {return};automatic=enabled;pausedByUser=false
        box.manager.stop()
        if enabled {box.manager.start()} else {box.manager.startOffline()}
    }
    func rebuild() {
        manualPausedScan = !automatic;pausedByUser=false
        box.manager.stop();box.manager.start();box.manager.rescan()
    }
    func cancelScan() {pausedByUser=true;box.manager.stop();box.manager.startOffline()}
    func stop() {polling?.cancel();box.manager.stop()}
}

private final class OilQuickWatcherBox: @unchecked Sendable {
    let watcher:FSWatcher
    init(path:String,onChange:@escaping @MainActor @Sendable ()->Void) {
        // Create the callback outside a MainActor context; Core delivers it on its event queue.
        watcher=FSWatcher(paths:[path],sinceWhen:UInt64.max,queue:DispatchQueue(label:"findduck.today.events",qos:.utility)) { changes,rescan in
            if !changes.isEmpty || rescan {Task { @MainActor in onChange() }}
        }
        _=watcher.start()
    }
}
@MainActor final class OilQuickWatcher {
    private let box:OilQuickWatcherBox
    init(root:URL,onChange:@escaping @MainActor @Sendable ()->Void) {
        var path=root.path
        if let resolved=realpath(path,nil) {path=String(cString:resolved);free(resolved)}
        box=OilQuickWatcherBox(path:path,onChange:onChange)
    }
    func stop() {box.watcher.stop()}
    deinit {box.watcher.stop()}
}
