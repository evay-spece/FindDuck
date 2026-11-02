import Foundation

struct LocalIndexOptions: Codable, Sendable {
    var indexSystemDirs = false
    var indexUserLibrary = false
    var indexDependencyDirs = false
    var indexPackageContents = false
}
struct LocalIndexScope: Sendable {
    // Matches Oil Find's default directory and package scope, with explicit WeChat access.
    static let dependencies = Set("node_modules site-packages .venv venv Pods DerivedData .git .svn .hg bower_components __pycache__ .gradle .cargo .rustup .npm .pnpm-store .yarn .cache .next .nuxt .build .swiftpm .tox .mypy_cache .pytest_cache .terraform".split(separator:" ").map(String.init))
    static let packages = Set("app bundle framework plugin kext appex xpc prefpane qlgenerator mdimporter saver component vst vst3 photoslibrary musiclibrary tvlibrary fcpbundle imovielibrary xcodeproj xcworkspace playground xcarchive dsym rtfd scptd lproj logicx band screenstudio pages numbers key".split(separator:" ").map(String.init))
    static let excludedNames = Set(".Spotlight-V100 .fseventsd .DocumentRevisions-V100 .TemporaryItems .Trashes .MobileBackups".split(separator:" ").map(String.init))
    let options: LocalIndexOptions
    let home: String
    let wechatPaths: [String]
    init(options:LocalIndexOptions = LocalIndexOptions(),wechat:URL? = nil,home:URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.options=options;self.home=home.standardizedFileURL.path
        let candidates=["Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files", "Library/Containers/com.tencent.xinWeChat/Data/Documents/WeChat Files", "Documents/xwechat_files"]
        wechatPaths=Array(Set(candidates.map {home.appendingPathComponent($0).standardizedFileURL.path} + (wechat.map {[$0.standardizedFileURL.path]} ?? [])))
    }
    var fingerprint: String {
        "oil-scope-v1:\(options.indexSystemDirs):\(options.indexUserLibrary):\(options.indexDependencyDirs):\(options.indexPackageContents):\(home):" + wechatPaths.sorted().joined(separator:"|")
    }
    private func under(_ path:String,_ root:String) -> Bool {path == root || path.hasPrefix(root + "/")}
    func stopsAtPackage(_ url:URL) -> Bool { !options.indexPackageContents && Self.packages.contains(url.pathExtension.lowercased()) }
    func excludes(_ url:URL,isDirectory:Bool) -> Bool {
        let path=url.standardizedFileURL.path
        if ["/System/Volumes","/dev","/cores","/.vol"].contains(where:{under(path,$0)}) {return true}
        if !options.indexSystemDirs {
            if ["/Library","/usr","/bin","/sbin","/private","/opt"].contains(where:{under(path,$0)}) {return true}
            if under(path,"/System"), path != "/System", !under(path,"/System/Applications") {return true}
            if !isDirectory && url.deletingLastPathComponent().path == "/System" {return true}
        }
        let library=home + "/Library"
        if !options.indexUserLibrary && under(path,library) {
            if path == library {return !isDirectory}
            let cloud=under(path,library + "/Mobile Documents") || under(path,library + "/CloudStorage")
            let wechat=wechatPaths.contains {under(path,$0) || (isDirectory && under($0,path))}
            if !cloud && !wechat {return true}
        }
        let components=path.split(separator:"/").map(String.init)
        for (position,name) in components.enumerated() {
            let ancestor=position < components.count-1
            if (ancestor || isDirectory) && Self.excludedNames.contains(name) {return true}
            if (ancestor || isDirectory) && !options.indexDependencyDirs && Self.dependencies.contains(name) {return true}
            if ancestor && !options.indexPackageContents && Self.packages.contains((name as NSString).pathExtension.lowercased()) {return true}
        }
        return false
    }
}
