import Foundation

struct TodayQuickScan: Sendable {let files:[FileHit];let warning:String}
enum TodayQuickScanner {
    static func scan(quick:QuickScope,root:URL,policy:ScanPolicy,now:Date=Date()) async throws -> TodayQuickScan {
        try Task.checkCancellation()
        guard DirectoryReader.available(root) else {throw IndexFailure(message:"目录不可读取，请检查路径和磁盘权限。")}
        if DuckExclusions(policy.excludedPaths).contains(root) {return TodayQuickScan(files:[],warning:"此文件夹在黑名单中，未读取其内容。")}
        let selection=quick == .wechat ? try wechatRoots(root,now:now,policy:policy) : ([root],[])
        let roots=selection.0
        var files=Dictionary(selection.1.map {($0.id,$0)},uniquingKeysWith:{a,_ in a}),unreadable=0
        for folder in roots {
            try Task.checkCancellation()
            let snapshot=try await DirectoryReader.full(folder,policy:policy) {_,_ in}
            for file in snapshot.files where !WechatLocations.isOpaqueImage(file.url) {files[file.id]=file}
            unreadable += snapshot.unreadablePaths?.count ?? 0
        }
        let warning=unreadable > 0 ? "已补查，部分文件夹无法读取；请检查磁盘权限。" : roots.isEmpty && files.isEmpty ? "未找到近期微信附件目录，请核对微信接收路径。" : ""
        return TodayQuickScan(files:Array(files.values),warning:warning)
    }
    private static func wechatRoots(_ root:URL,now:Date,policy:ScanPolicy) throws -> ([URL],[FileHit]) {
        let manager=FileManager.default,calendar=Calendar.current
        let formatter=DateFormatter();formatter.calendar=calendar;formatter.locale=Locale(identifier:"en_US_POSIX");formatter.dateFormat="yyyy-MM"
        let month=formatter.string(from:now)
        let previous=formatter.string(from:calendar.date(byAdding:.month,value:-1,to:now) ?? now)
        let bases=WechatLocations.attachmentRoots(in:root)
        // A custom attachment directory can be used directly. Never recursively scan
        // the whole xwechat_files tree when the installed WeChat layout is unknown.
        if bases.isEmpty {return ([],[])}
        var roots=Set<URL>(),direct:[FileHit]=[]
        for base in bases {
            let nested=["attach","MsgAttach"].contains(base.lastPathComponent)
            let parents=nested ? (try manager.contentsOfDirectory(at:base,includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles])).filter {
                (try? $0.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true
            } : [base]
            for parent in parents {
                try Task.checkCancellation()
                let children=try manager.contentsOfDirectory(at:parent,includingPropertiesForKeys:[.isDirectoryKey,.contentModificationDateKey],options:[.skipsHiddenFiles])
                var directFiles=false
                for child in children {
                    try Task.checkCancellation()
                    let values=try child.resourceValues(forKeys:[.isDirectoryKey,.contentModificationDateKey])
                    if values.isDirectory != true {directFiles=true;continue}
                    let recentName=child.lastPathComponent.hasPrefix(month) || child.lastPathComponent.hasPrefix(previous)
                    if recentName || values.contentModificationDate.map({calendar.isDate($0,inSameDayAs:now)}) == true {roots.insert(child)}
                }
                if directFiles {direct.append(contentsOf:try DirectoryReader.read(parent,policy:policy).files.filter {!WechatLocations.isOpaqueImage($0.url)})}
            }
        }
        return (Array(roots),direct)
    }
}
