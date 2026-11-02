import AppKit

enum DuckMenuBarIcon {
    static let logicalSize = NSSize(width: 20, height: 20)
    @MainActor static func load(resources: URL? = Bundle.main.resourceURL) -> NSImage? {
        let image = NSImage(size: logicalSize)
        if let resources {
            let names = ["RocketDuckTemplate_Source.png", "RocketDuckTemplate_54.png"]
            for name in names {
                guard let data = try? Data(contentsOf: resources.appendingPathComponent(name)),
                      let source = NSBitmapImageRep(data: data)?.cgImage,
                      let cropped = trimmed(source) else { continue }
                for scale in 1...3 {
                    let pixels = 20 * scale
                    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                        bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                    let factor = CGFloat(19 * scale) / CGFloat(max(cropped.width, cropped.height))
                    let width = CGFloat(cropped.width) * factor, height = CGFloat(cropped.height) * factor
                    context.interpolationQuality = .high
                    context.draw(cropped, in: CGRect(x: (CGFloat(pixels)-width)/2, y: (CGFloat(pixels)-height)/2, width: width, height: height))
                    guard let rendered = context.makeImage() else { continue }
                    let rep = NSBitmapImageRep(cgImage: rendered)
                    rep.size = logicalSize
                    image.addRepresentation(rep)
                }
                break
            }
        }
        guard !image.representations.isEmpty else { return NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "找鸭") }
        image.isTemplate = true
        image.accessibilityDescription = "找鸭"
        return image
    }
    private static func trimmed(_ source: CGImage) -> CGImage? {
        let width = source.width, height = source.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        var left = width, top = height, right = -1, bottom = -1
        for y in 0..<height {
            for x in 0..<width where data[(y * width + x) * 4 + 3] >= 8 {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top else { return nil }
        return source.cropping(to: CGRect(x: left, y: top, width: right-left+1, height: bottom-top+1))
    }
}
