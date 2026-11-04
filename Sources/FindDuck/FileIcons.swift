import AppKit
import UniformTypeIdentifiers

@MainActor final class FileIcons {
    static let shared = FileIcons()
    private let cache = NSCache<NSString, NSImage>()
    private var refreshed = Date()
    init() { cache.countLimit = 200 }
    func application(for file: FileHit) -> URL? {
        guard !file.isDirectory, let type = UTType(filenameExtension: file.url.pathExtension) else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: type)
    }
    func icon(for file: FileHit) -> NSImage {
        if Date().timeIntervalSince(refreshed) > 60 { cache.removeAllObjects(); refreshed = Date() }
        if file.url.pathExtension.lowercased() == "app" {return NSWorkspace.shared.icon(forFile:file.url.path)}
        let key = (file.isDirectory ? "folder" : "ext:" + file.url.pathExtension.lowercased()) as NSString
        if let image = cache.object(forKey: key) { return image }
        let image: NSImage
        if file.isDirectory { image = NSWorkspace.shared.icon(for: .folder) }
        else if let app = application(for: file) { image = NSWorkspace.shared.icon(forFile: app.path) }
        else { image = NSWorkspace.shared.icon(for: UTType(filenameExtension:file.url.pathExtension) ?? .data) }
        cache.setObject(image, forKey: key)
        return image
    }
}
