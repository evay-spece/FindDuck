import AppKit
import SwiftUI

struct AppRelease: Decodable {
    let tag_name: String

    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }

    static func versionParts(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else {
            return nil
        }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil
    }

    func updateLevel(comparedTo current: String) -> Int? {
        guard let installed = Self.versionParts(current), let available = Self.versionParts(version),
              installed.lexicographicallyPrecedes(available) else { return nil }
        return installed.indices.first { installed[$0] != available[$0] }
    }

    var page: URL {
        URL(string: "https://github.com/evay-spece/FindDuck/releases/tag")!.appendingPathComponent(tag_name)
    }
}

@MainActor final class AppUpdates: ObservableObject {
    @Published private(set) var release: AppRelease?
    @Published private(set) var checking = false
    @Published private(set) var status = ""
    @Published var aboutRequest = 0

    private let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    private let notifiedKey = "siuLastUpdatePopupVersion"
    private let endpoint = URL(string: "https://api.github.com/repos/evay-spece/FindDuck/releases/latest")!
    private var wantsStatus = false
    var hasSmallUpdate: Bool { release?.updateLevel(comparedTo: current) == 2 }

    func check(manual: Bool = false) async {
        wantsStatus = wantsStatus || manual
        guard !checking else { return }
        checking = true
        defer { checking = false; wantsStatus = false }
        do {
            let request = URLRequest(url: endpoint, timeoutInterval: 15)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let latest = try JSONDecoder().decode(AppRelease.self, from: data)
            guard AppRelease.versionParts(latest.version) != nil else { throw URLError(.cannotParseResponse) }
            release = latest.updateLevel(comparedTo: current) == nil ? nil : latest
            status = wantsStatus && release == nil ? "当前已是最新版本" : ""
        } catch {
            if wantsStatus { status = "暂时无法检查更新，请稍后重试。" }
        }
        presentUpdateIfNeeded()
    }

    func presentUpdateIfNeeded() {
        guard NSApp.isActive, let release, let level = release.updateLevel(comparedTo: current), level < 2,
              UserDefaults.standard.string(forKey: notifiedKey) != release.version else { return }
        UserDefaults.standard.set(release.version, forKey: notifiedKey)
        let alert = NSAlert()
        alert.messageText = "Biu \(release.version) 可更新"
        alert.informativeText = "当前版本为 \(current)。打开发布页查看更新内容并下载。"
        alert.addButton(withTitle: "查看更新")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
    }
}
