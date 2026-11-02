import Foundation
@preconcurrency import OilFindCore

enum OilSnapshotStore {
    static func make(_ snapshot:NameIndex) -> OilStoreHandle {
        let root=snapshot.root.standardizedFileURL.path
        var buffer=ScanBuffer(),ids:[String:UInt32]=[:]
        func append(path:String,name:String,parent:UInt32,directory:Bool,modified:Date?) -> UInt32 {
            let id=UInt32(buffer.ids.count),bytes=Array(name.utf8)
            var flags:SiftFlagValue = directory ? SiftFlag.dir | SiftFlag.userArea : SiftFlag.userArea
            if !directory && (name as NSString).pathExtension.lowercased() == "app" {flags |= SiftFlag.package}
            let kind=bytes.withUnsafeBufferPointer {Classifier.kind(name:$0,flags:flags)}
            buffer.ids.append(id);buffer.parents.append(parent);buffer.sizes.append(0)
            buffer.mtimes.append(UInt32(clamping:Int64(modified?.timeIntervalSince1970 ?? 0)))
            buffer.flags.append(flags);buffer.depths.append(UInt8(clamping:path.split(separator:"/").count));buffer.kinds.append(kind)
            buffer.nameLens.append(UInt32(bytes.count));buffer.nameBytes.append(contentsOf:bytes);ids[path]=id
            return id
        }
        _=append(path:root,name:"",parent:0,directory:true,modified:nil)
        func directory(_ path:String) -> UInt32 {
            if let id=ids[path] {return id}
            let parentPath=(path as NSString).deletingLastPathComponent
            let parent=directory(parentPath == path ? root : parentPath)
            return append(path:path,name:(path as NSString).lastPathComponent,parent:parent,directory:true,modified:nil)
        }
        for record in snapshot.directories ?? [] where DuckRules.under(record.url,snapshot.root) {
            let id=directory(record.url.standardizedFileURL.path)
            buffer.mtimes[Int(id)]=UInt32(clamping:Int64(record.modified?.timeIntervalSince1970 ?? 0))
        }
        for file in snapshot.files where DuckRules.under(file.url,snapshot.root) {
            let path=file.url.standardizedFileURL.path
            if ids[path] != nil {continue}
            let parent=directory((path as NSString).deletingLastPathComponent)
            _=append(path:path,name:file.name,parent:parent,directory:file.isDirectory,modified:file.modified)
        }
        let config=IndexConfig(rootPath:root,indexDependencyDirs:true,indexPackageContents:true,indexUserLibrary:true,indexSystemDirs:true)
        let output=ScanOutput(buffers:[buffer],count:buffer.ids.count,homeIndex:0,elapsed:0,finishedAt:UInt64(Date().timeIntervalSince1970))
        let store=IndexStore(scan:output,config:config,caseSensitiveNamesOverride:true);store.write {store.buildHash()}
        let explicit=Set((snapshot.directories ?? []).map {$0.url.standardizedFileURL.path})
        let hidden:Set<UInt32> = root == "/" && !explicit.isEmpty ? Set(ids.filter {$0.value != 0 && !explicit.contains($0.key) && buffer.flags[Int($0.value)] & SiftFlag.dir != 0}.map(\.value)) : []
        return OilStoreHandle(id:"shared:"+root,store:store,hiddenEntryIDs:hidden)
    }
    private typealias SiftFlagValue = UInt8
}
