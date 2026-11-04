import AppKit
import Combine

struct RecentAppEntry:Codable,Identifiable,Equatable {
    let path:String
    let name:String
    let bundleID:String?
    let openedAt:Date
    var id:String {path}
}

@MainActor final class RecentAppLibrary:ObservableObject {
    @Published private(set) var items:[RecentAppEntry]=[]
    private let file:URL
    private var observers:[NSObjectProtocol]=[]
    init(file:URL?=nil,watch:Bool=true) {
        self.file=file ?? BiuStorage.directory.appendingPathComponent("recent-apps.json")
        if let data=try? Data(contentsOf:self.file),let entries=try? JSONDecoder().decode([RecentAppEntry].self,from:data) {
            for entry in entries.sorted(by:{$0.openedAt < $1.openedAt}) where FileManager.default.fileExists(atPath:entry.path) {record(entry,persist:false)}
        }
        if watch {start()}
    }
    func record(_ entry:RecentAppEntry,persist:Bool=true) {
        guard entry.path.hasPrefix("/"),URL(fileURLWithPath:entry.path).pathExtension.lowercased() == "app",entry.bundleID != BiuStorage.identifier, entry.bundleID != BiuStorage.legacyIdentifier,!entry.name.isEmpty else {return}
        let path=URL(fileURLWithPath:entry.path).standardizedFileURL.path
        guard !items.contains(where:{($0.path == path || (entry.bundleID != nil && $0.bundleID == entry.bundleID)) && $0.openedAt > entry.openedAt}) else {return}
        items.removeAll {$0.path == path || (entry.bundleID != nil && $0.bundleID == entry.bundleID)}
        items.append(RecentAppEntry(path:path,name:entry.name,bundleID:entry.bundleID,openedAt:entry.openedAt))
        items.sort {$0.openedAt == $1.openedAt ? $0.path < $1.path : $0.openedAt > $1.openedAt};items=Array(items.prefix(20))
        if persist {save()}
    }
    func visible(excluding pinned:[HomeShortcut],limit:Int=5)->[RecentAppEntry] {
        let paths=Set(pinned.filter {$0.kind == .application}.map {URL(fileURLWithPath:$0.target).standardizedFileURL.path})
        let bundles=Set(pinned.filter {$0.kind == .application}.compactMap {DockBadgeStore.applicationIdentifier(URL(fileURLWithPath:$0.target))})
        return Array(items.filter {!paths.contains($0.path) && ($0.bundleID.map {!bundles.contains($0)} ?? true)}.prefix(max(0,limit)))
    }
    private func start() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let entry=entry(app,date:app.launchDate ?? .distantPast) {record(entry,persist:false)}
        }
        save()
        for name in [NSWorkspace.didLaunchApplicationNotification,NSWorkspace.didActivateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main) { [weak self] notification in
                guard let app=notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {return}
                let pid=app.processIdentifier,date=Date()
                Task { @MainActor [weak self] in
                    guard let self,let app=NSRunningApplication(processIdentifier:pid),app.activationPolicy == .regular,let entry=self.entry(app,date:date) else {return}
                    self.record(entry)
                }
            })
        }
    }
    private func entry(_ app:NSRunningApplication,date:Date)->RecentAppEntry? {
        guard let url=app.bundleURL else {return nil}
        return RecentAppEntry(path:url.standardizedFileURL.path,name:app.localizedName ?? url.deletingPathExtension().lastPathComponent,bundleID:app.bundleIdentifier,openedAt:date)
    }
    func stop() {for observer in observers {NSWorkspace.shared.notificationCenter.removeObserver(observer)};observers=[]}
    private func save() {
        do {try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONEncoder().encode(items).write(to:file,options:.atomic)} catch {}
    }
}
