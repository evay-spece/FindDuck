import Foundation

public enum TmallLinkError: Error, Equatable, LocalizedError {
    case emptyInput
    case productIDNotFound

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "请先粘贴天猫商品链接"
        case .productIDNotFound:
            return "没有识别到天猫或京东商品 ID，请检查链接是否完整"
        }
    }
}

public enum ShoppingPlatform: String, Equatable, Sendable {
    case tmall = "天猫"
    case jd = "京东"
}

public struct CleanedProductLink: Equatable, Sendable {
    public let platform: ShoppingPlatform
    public let productID: String
    public let url: String

    public init(platform: ShoppingPlatform, productID: String, url: String) {
        self.platform = platform
        self.productID = productID
        self.url = url
    }
}

public enum TmallLinkParser {
    private static let tmallDomainPattern = #"(?i)(?:[a-z0-9-]+\.)*tmall\.(?:com|hk)"#
    private static let tmallProductIDPattern = #"(?i)[?&](?:id|itemid|item_id)=([0-9]{5,20})(?=[^0-9]|$)"#
    private static let jdDomainPattern = #"(?i)(?:[a-z0-9-]+\.)*jd\.com"#
    private static let jdPathProductIDPattern = #"(?i)/(?:product/)?([0-9]{5,20})\.html(?=[^a-z0-9]|$)"#
    private static let jdQueryProductIDPattern = #"(?i)[?&](?:wareid|skuid|sku|id)=([0-9]{5,20})(?=[^0-9]|$)"#

    public static func clean(_ input: String) throws -> String {
        try analyze(input).url
    }

    public static func analyze(
        _ input: String,
        numericPlatform: ShoppingPlatform = .tmall
    ) throws -> CleanedProductLink {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TmallLinkError.emptyInput
        }

        if trimmed.range(of: #"^[0-9]{1,20}$"#, options: .regularExpression) != nil {
            return makeResult(platform: numericPlatform, productID: trimmed)
        }

        for candidate in decodingCandidates(from: trimmed) {
            if candidate.range(of: tmallDomainPattern, options: .regularExpression) != nil,
               let productID = firstCapture(in: candidate, pattern: tmallProductIDPattern) {
                return makeResult(platform: .tmall, productID: productID)
            }

            if candidate.range(of: jdDomainPattern, options: .regularExpression) != nil {
                if let productID = firstCapture(in: candidate, pattern: jdPathProductIDPattern) {
                    return makeResult(platform: .jd, productID: productID)
                }
                if let productID = firstCapture(in: candidate, pattern: jdQueryProductIDPattern) {
                    return makeResult(platform: .jd, productID: productID)
                }
            }
        }

        throw TmallLinkError.productIDNotFound
    }

    public static func canonicalLink(for productID: String) -> String {
        "https://detail.tmall.com/item.htm?id=\(productID)"
    }

    public static func canonicalJDLink(for productID: String) -> String {
        "https://item.jd.com/\(productID).html"
    }

    private static func makeResult(platform: ShoppingPlatform, productID: String) -> CleanedProductLink {
        let url: String
        switch platform {
        case .tmall:
            url = canonicalLink(for: productID)
        case .jd:
            url = canonicalJDLink(for: productID)
        }
        return CleanedProductLink(platform: platform, productID: productID, url: url)
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: range),
            let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[captureRange])
    }

    private static func decodingCandidates(from input: String) -> [String] {
        var candidates = [input.replacingOccurrences(of: "&amp;", with: "&")]
        var current = input

        for _ in 0..<2 {
            guard let decoded = current.removingPercentEncoding, decoded != current else {
                break
            }
            candidates.append(decoded.replacingOccurrences(of: "&amp;", with: "&"))
            current = decoded
        }

        return candidates
    }
}
