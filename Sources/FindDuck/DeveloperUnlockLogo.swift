import AppKit
import QuartzCore
import SwiftUI

struct DeveloperUnlockLogo: NSViewRepresentable {
    var onUnlock: () -> Void

    func makeNSView(context: Context) -> DeveloperLogoView {
        let view = DeveloperLogoView()
        view.onUnlock = onUnlock
        return view
    }

    func updateNSView(_ view: DeveloperLogoView, context: Context) { view.onUnlock = onUnlock }

    static func dismantleNSView(_ view: DeveloperLogoView, coordinator: ()) { view.stop() }
}

final class DeveloperLogoView: NSView {
    var onUnlock: (() -> Void)?
    private var sequence = RightClickEasterEggSequence()
    private var resignObserver: NSObjectProtocol?
    private let normalIcon = NSApp.applicationIconImage ?? NSImage(size: NSSize(width: 64, height: 64))
    private lazy var redIcon = Self.makeRedIcon(normalIcon)

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("找鸭标志")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.disarm() } }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        sequence.arm()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard sequence.isArmed else { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else {
            disarm()
            super.keyDown(with: event)
            return
        }
        let feedback = sequence.handle(keyCode: event.keyCode, isDown: true,
                                       isRepeat: event.isARepeat, at: event.timestamp)
        if feedback != .ignored { flash() }
        if feedback == .unlocked { onUnlock?() }
    }

    override func keyUp(with event: NSEvent) {
        guard sequence.isArmed else { super.keyUp(with: event); return }
        _ = sequence.handle(keyCode: event.keyCode, isDown: false, at: event.timestamp)
    }

    override func resignFirstResponder() -> Bool {
        disarm()
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        (sequence.isArmed ? redIcon : normalIcon).draw(in: bounds)
    }

    private func flash() {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.2
        animation.toValue = 1
        animation.duration = 0.16
        layer?.add(animation, forKey: "keyFlash")
        needsDisplay = true
    }

    private func disarm() {
        sequence.reset()
        layer?.removeAnimation(forKey: "keyFlash")
        needsDisplay = true
    }

    func stop() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        disarm()
    }

    private static func makeRedIcon(_ image: NSImage) -> NSImage {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
        NSGraphicsContext.restoreGraphicsState()
        for y in 0..<128 {
            for x in 0..<128 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
                color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                if saturation > 0.08 {
                    bitmap.setColor(NSColor(deviceHue: 0, saturation: saturation,
                                            brightness: brightness, alpha: alpha), atX: x, y: y)
                }
            }
        }
        let result = NSImage(size: NSSize(width: 64, height: 64))
        result.addRepresentation(bitmap)
        return result
    }
}
