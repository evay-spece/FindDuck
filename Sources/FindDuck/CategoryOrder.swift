import SwiftUI

@MainActor final class CategoryOrder: ObservableObject {
    @Published private(set) var categories: [ResultCategory]
    @Published var dropTarget: ResultCategory?
    @Published private(set) var error = ""
    private let file: URL
    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.chenhuang.smbsearch/category-order.json")
        let saved = (try? Data(contentsOf: self.file)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        var seen = Set<String>()
        categories = saved.compactMap { name -> ResultCategory? in
            guard let category = ResultCategory(rawValue: name), seen.insert(name).inserted else { return nil }
            return category
        }
        categories += ResultCategory.allCases.filter { !seen.contains($0.rawValue) }
    }
    @discardableResult func move(_ source: ResultCategory, to target: ResultCategory) -> Bool {
        guard let from = categories.firstIndex(of: source), let to = categories.firstIndex(of: target), from != to else { return false }
        let previous = categories
        let category = categories.remove(at: from)
        categories.insert(category, at: to)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(categories.map(\.rawValue)).write(to: file, options: .atomic)
            error = ""
        } catch {
            categories = previous
            self.error = "分类顺序保存失败，请检查本机存储权限。"
            return false
        }
        return true
    }
    @discardableResult func drop(_ values: [String], on target: ResultCategory) -> Bool {
        guard let value = values.first, value.hasPrefix("findduck-category:"), let category = ResultCategory(rawValue: String(value.dropFirst("findduck-category:".count))) else { return false }
        dropTarget = nil
        return move(category, to: target)
    }
}
