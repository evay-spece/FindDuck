import AppKit
import SwiftUI
import ApplicationServices

@MainActor final class DockBadgeStore:ObservableObject {
    @Published private(set) var badges:[String:String]=[:]
    @Published private(set) var trusted=false
    nonisolated static func normalized(_ raw:String)->String? {
        let value=raw.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:",",with:"")
        let digits=value.hasSuffix("+") ? String(value.dropLast()) : value
        guard !digits.isEmpty,digits.allSatisfy({$0.isASCII && $0.isNumber}),let number=Int(digits),number>0 else {return nil}
        return number>999 ? "999+" : value
    }
    func badge(for path:String)->String? {
        guard trusted,!badges.isEmpty,path.hasPrefix("/") else {return nil}
        let url=URL(fileURLWithPath:path)
        if let value=badges[url.standardizedFileURL.path] {return value}
        if let id=Self.applicationIdentifier(url) {return badges["bundle:"+id]};return nil
    }
    nonisolated static func applicationIdentifier(_ url:URL)->String? {
        guard url.isFileURL,url.pathExtension.lowercased() == "app",
              let data=try? Data(contentsOf:url.appendingPathComponent("Contents/Info.plist")),
              let info=(try? PropertyListSerialization.propertyList(from:data,format:nil)) as? [String:Any]
        else {return nil}
        return info["CFBundleIdentifier"] as? String
    }
    func requestPermission() {_=AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt":true] as CFDictionary)}
    func watch() async {
        while !Task.isCancelled {
            let allowed=AXIsProcessTrusted();if trusted != allowed {trusted=allowed}
            if allowed,NSApp.isActive,let pid=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock").first?.processIdentifier {
                let result=await Task.detached(priority:.utility) {Self.readDock(pid:pid)}.value
                guard !Task.isCancelled else {return};if result != badges {badges=result}
            } else if !allowed,!badges.isEmpty {badges=[:]}
            do {try await Task.sleep(for:.seconds(5))} catch {return}
        }
    }
    nonisolated private static func readDock(pid:pid_t)->[String:String] {
        let root=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(root,0.15)
        func value(_ node:AXUIElement,_ key:String)->CFTypeRef? {var v:CFTypeRef?;guard AXUIElementCopyAttributeValue(node,key as CFString,&v) == .success else {return nil};return v}
        var queue=[root],position=0,result:[String:String]=[:]
        while position<queue.count,position<500,!Task.isCancelled {
            let node=queue[position];position += 1
            if let status=value(node,"AXStatusLabel") as? String,let badge=normalized(status) {
                let raw=value(node,kAXURLAttribute as String)
                let url=(raw as? URL) ?? (raw as? String).flatMap {URL(string:$0)}
                if let url,url.isFileURL {result[url.standardizedFileURL.path]=badge;if let id=applicationIdentifier(url) {result["bundle:"+id]=badge}}
            }
            if let children=value(node,kAXChildrenAttribute as String) as? [AXUIElement] {queue.append(contentsOf:children)}
        }
        return result
    }
}
