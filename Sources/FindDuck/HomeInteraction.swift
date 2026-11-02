import AppKit
import SwiftUI

struct HomeItemInteraction:NSViewRepresentable {
    let id:UUID
    let title:String
    let help:String
    let dragImage:NSImage
    let dragSize:CGFloat
    let action:()->Void
    let hover:(Bool)->Void
    let menu:()->NSMenu
    let accept:(UUID)->Bool
    let drop:(UUID)->Void
    let frameChanged:(@escaping ()->CGRect?)->Void
    let dragBegan:()->Void
    let dragMoved:(CGPoint)->Void
    let dragEnded:()->Void
    func makeNSView(context:Context)->Surface {Surface()}
    func updateNSView(_ view:Surface,context:Context) {view.itemID=id;view.action=action;view.hover=hover;view.makeMenu=menu;view.accept=accept;view.drop=drop;view.dragImage=dragImage;view.dragSize=dragSize;view.dragBegan=dragBegan;view.dragMoved=dragMoved;view.dragEnded=dragEnded;view.setAccessibilityLabel("主页入口："+title);view.setAccessibilityHelp(help);frameChanged { [weak view] in guard let view,view.window != nil else {return nil};return view.convert(view.bounds,to:nil)}}
    final class Surface:NSView,NSDraggingSource {
        var itemID=UUID()
        var dragImage:NSImage?;var dragSize:CGFloat=50
        var dragBegan:(()->Void)?;var dragMoved:((CGPoint)->Void)?;var dragEnded:(()->Void)?
        var action:(()->Void)?;var hover:((Bool)->Void)?;var makeMenu:(()->NSMenu)?;var accept:((UUID)->Bool)?;var drop:((UUID)->Void)?
        private var down:NSEvent?,dragged=false,tracking:NSTrackingArea?
        override init(frame:NSRect) {super.init(frame:frame);registerForDraggedTypes([.string]);setAccessibilityElement(true);setAccessibilityRole(.button)}
        required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
        override func accessibilityPerformPress()->Bool {action?();return true}
        override func hitTest(_ point:NSPoint)->NSView? {isHidden ? nil : (bounds.contains(convert(point,from:superview)) ? self : nil)}
        override func updateTrackingAreas() {super.updateTrackingAreas();guard tracking == nil else {return};let value=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil);tracking=value;addTrackingArea(value)}
        override func mouseEntered(with event:NSEvent) {hover?(true)}
        override func mouseExited(with event:NSEvent) {hover?(false)}
        override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
        override func mouseDown(with event:NSEvent) {down=event;dragged=false}
        override func mouseDragged(with event:NSEvent) {
            guard let down,!dragged,hypot(event.locationInWindow.x-down.locationInWindow.x,event.locationInWindow.y-down.locationInWindow.y)>4 else {return}
            dragged=true
            dragBegan?()
            let item=NSDraggingItem(pasteboardWriter:("findduck-home:"+itemID.uuidString) as NSString)
            let point=convert(event.locationInWindow,from:nil)
            item.setDraggingFrame(NSRect(x:point.x-dragSize/2,y:point.y-dragSize/2,width:dragSize,height:dragSize),contents:dragImage)
            beginDraggingSession(with:[item],event:event,source:self)
        }
        override func mouseUp(with event:NSEvent) {defer {down=nil};if !dragged,bounds.contains(convert(event.locationInWindow,from:nil)) {action?()}}
        override func rightMouseDown(with event:NSEvent) {if let menu=makeMenu?() {NSMenu.popUpContextMenu(menu,with:event,for:self)}}
        func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation {.move}
        func draggingSession(_ session:NSDraggingSession,movedTo screenPoint:NSPoint) {if let window {dragMoved?(window.convertPoint(fromScreen:screenPoint))}}
        func draggingSession(_ session:NSDraggingSession,endedAt screenPoint:NSPoint,operation:NSDragOperation) {dragEnded?();down=nil;hover?(false)}
        private func source(_ sender:any NSDraggingInfo)->UUID? {guard let s=sender.draggingPasteboard.string(forType:.string),s.hasPrefix("findduck-home:") else {return nil};return UUID(uuidString:String(s.dropFirst("findduck-home:".count)))}
        override func draggingEntered(_ sender:any NSDraggingInfo)->NSDragOperation {guard let id=source(sender),accept?(id) == true else {return []};hover?(true);return .move}
        override func draggingUpdated(_ sender:any NSDraggingInfo)->NSDragOperation {guard let id=source(sender),accept?(id) == true else {return []};return .move}
        override func draggingExited(_ sender:(any NSDraggingInfo)?) {hover?(false)}
        override func performDragOperation(_ sender:any NSDraggingInfo)->Bool {hover?(false);guard let id=source(sender),accept?(id) == true else {return false};drop?(id);return true}
    }
}
struct HomeFileDropArea:NSViewRepresentable {
    let drop:([URL])->Void
    func makeNSView(context:Context)->Surface {Surface()}
    func updateNSView(_ view:Surface,context:Context) {view.drop=drop}
    final class Surface:NSView {
        var drop:(([URL])->Void)?;private var targeted=false
        override init(frame:NSRect) {super.init(frame:frame);registerForDraggedTypes([.fileURL]);setAccessibilityElement(true);setAccessibilityRole(.group);setAccessibilityLabel("拖入文件或文件夹，固定到常用文件")}
        required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
        private func urls(_ sender:any NSDraggingInfo)->[URL] {(sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]) ?? []}
        override func draggingEntered(_ sender:any NSDraggingInfo)->NSDragOperation {guard !urls(sender).isEmpty else {return []};targeted=true;needsDisplay=true;return .copy}
        override func draggingExited(_ sender:(any NSDraggingInfo)?) {targeted=false;needsDisplay=true}
        override func performDragOperation(_ sender:any NSDraggingInfo)->Bool {let values=urls(sender);targeted=false;needsDisplay=true;guard !values.isEmpty else {return false};drop?(values);return true}
        override func draw(_ dirtyRect:NSRect) {
            let rect=bounds.insetBy(dx:1,dy:1),path=NSBezierPath(roundedRect:rect,xRadius:10,yRadius:10)
            (targeted ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.labelColor.withAlphaComponent(0.025)).setFill();path.fill()
            NSColor.separatorColor.setStroke();path.setLineDash([4,4],count:2,phase:0);path.stroke()
            let text="＋ 拖入文件或文件夹，固定到这里" as NSString,attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.secondaryLabelColor]
            let size=text.size(withAttributes:attrs);text.draw(at:NSPoint(x:max(8,(bounds.width-size.width)/2),y:(bounds.height-size.height)/2),withAttributes:attrs)
        }
    }
}
