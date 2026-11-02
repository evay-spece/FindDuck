import Foundation

enum WechatLocations {
    static func locate(home:URL,existing:URL?=nil)->URL? {
        // Keep a working detected/cached location, and recover when it moves or disappears.
        if let existing,DirectoryReader.available(existing) {return existing}
        let paths=["Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files",
                   "Library/Containers/com.tencent.xinWeChat/Data/Documents/WeChat Files",
                   "Documents/xwechat_files","Documents/WeChat Files"]
        return paths.map {home.appendingPathComponent($0)}.first {DirectoryReader.available($0)}
    }
}
