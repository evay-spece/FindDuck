import AppKit
import SwiftUI
import QuickLookUI

enum DisplayPath {
    private static let homeNames = ["Desktop":"桌面","Downloads":"下载","Documents":"文稿","Pictures":"图片","Movies":"影片","Music":"音乐","Applications":"应用程序","Library":"资源库","Public":"公共"]
    private static let systemNames = ["Users":"用户","Applications":"应用程序","Library":"资源库","System":"系统","Volumes":"宗卷"]

    static func name(_ url: URL) -> String {
        if url.path == "/" { return "/" }
        return localized(url).split(separator: "/").last.map(String.init) ?? url.lastPathComponent
    }

    static func localized(_ url: URL) -> String {
        let parts = url.standardizedFileURL.path.split(separator: "/").map(String.init)
        return "/" + parts.enumerated().map { index, part in
            if index == 0 { return systemNames[part] ?? part }
            if index == 2, parts.first == "Users" { return homeNames[part] ?? part }
            if index == 1, parts.first == "System" { return systemNames[part] ?? part }
            return part
        }.joined(separator: "/")
    }
    static func parent(_ url:URL,home:URL=FileManager.default.homeDirectoryForCurrentUser)->String {
        let path=url.deletingLastPathComponent().standardizedFileURL.path
        let parts=path.split(separator:"/").map(String.init)
        if let index=parts.firstIndex(where:{$0 == "xwechat_files" || $0 == "WeChat Files"}) {
            let tail=Array(parts.dropFirst(index+1))
            if let file=tail.firstIndex(where:{$0.lowercased() == "file"}) {return "微信文档/"+tail.dropFirst(file+1).joined(separator:"/")}
        }
        if path == home.path {return "/个人文件夹/"}
        if path.hasPrefix(home.path+"/") {let tail=path.dropFirst(home.path.count+1).split(separator:"/").map(String.init);return "/"+([homeNames[tail[0]] ?? tail[0]]+tail.dropFirst()).joined(separator:"/")+"/"}
        if parts.count >= 3,parts[0] == "Users" {return parts[1]+"/"+([homeNames[parts[2]] ?? parts[2]]+parts.dropFirst(3)).joined(separator:"/")+"/"}
        return localized(URL(fileURLWithPath: path))
    }
    static func highlighted(_ name:String,query:String)->AttributedString {
        var result=AttributedString(name)
        for term in query.split(whereSeparator:{$0.isWhitespace}).map(String.init) where !term.isEmpty {
            var cursor=name.startIndex
            while cursor < name.endIndex,let range=name.range(of:term,options:[.caseInsensitive,.diacriticInsensitive],range:cursor..<name.endIndex),let ar=Range(range,in:result) {
                result[ar].foregroundColor = .accentColor;result[ar].backgroundColor = FindDuckHighlight.soft;cursor=range.upperBound
            }
        }
        return result
    }
}
@MainActor final class FilePreview:NSObject,@preconcurrency QLPreviewPanelDataSource {
    static let shared=FilePreview()
    private var url:URL?
    func show(_ file:FileHit) {
        guard let panel=QLPreviewPanel.shared() else {return}
        if panel.isVisible,url == file.url {panel.orderOut(nil);return}
        url=file.url;panel.dataSource=self;panel.reloadData();panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel:QLPreviewPanel!)->Int {url == nil ? 0 : 1}
    func previewPanel(_ panel:QLPreviewPanel!,previewItemAt index:Int)->(any QLPreviewItem)! {url as NSURL?}
}
