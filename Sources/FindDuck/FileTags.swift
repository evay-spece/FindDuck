import SwiftUI
import AppKit

struct TagBadge:View {
    let tag:FileTag
    var highlighted=false
    @State private var hovering=false
    var body:some View {
        Group {
            if tag.name.isEmpty {Circle().fill(tag.color.color).frame(width:10,height:10)}
            else {Text(tag.name).font(.system(size:11,weight:.medium)).lineLimit(1).padding(.horizontal,8).padding(.vertical,3)
                .foregroundStyle(tag.color.labelColor).background(tag.color.tagBackground(highlighted:hovering || highlighted),in:RoundedRectangle(cornerRadius:6))
                .overlay(RoundedRectangle(cornerRadius:6).strokeBorder(tag.color.color.opacity(0.45),lineWidth:1))}
        }.onHover {hovering=$0}.help(tag.displayName).accessibilityLabel("找鸭标签："+tag.displayName)
    }
}
struct FileTagEditor:View {
    @ObservedObject var model:SearchLibrary
    let file:FileHit
    let create:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("文件标签").font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary)
            HStack(spacing:10) {
                ForEach(FileTag.defaults) {tag in
                    Button {model.toggleTag(file,tag)} label: {
                        ZStack {Circle().fill(tag.color.color.opacity(0.75));Circle().stroke(tag.color.color,lineWidth:1)
                            if model.hasTag(file,tag) {Image(systemName:"checkmark").font(.system(size:11,weight:.bold)).foregroundStyle(.white)}}.frame(width:24,height:24)
                    }.buttonStyle(.plain).accessibilityLabel(tag.color.rawValue+"标签").help(model.hasTag(file,tag) ? "移除"+tag.color.rawValue : "添加"+tag.color.rawValue)
                }
            }
            if let custom=model.preferences.customTags,!custom.isEmpty {
                ForEach(custom) {tag in
                    Button {model.toggleTag(file,tag)} label: {HStack {TagBadge(tag:tag);Spacer();if model.hasTag(file,tag) {Image(systemName:"checkmark").font(.caption)}}}
                        .buttonStyle(.plain).accessibilityLabel("标签："+tag.name)
                }
            }
            Divider()
            Button(action:create) {Label("自定义标签…",systemImage:"tag")}.buttonStyle(.plain)
        }.padding(16).frame(width:260)
    }
}
// A native menu view keeps all color choices directly visible, as in Finder.
@MainActor final class TagColorPalette:NSView {
    private var buttons:[ColorChoiceButton]=[]
    private let selected:()->Set<FileMarkColor>
    private let toggle:(FileMarkColor)->Void
    init(selected:@escaping ()->Set<FileMarkColor>,toggle:@escaping (FileMarkColor)->Void) {
        self.selected=selected;self.toggle=toggle;super.init(frame:NSRect(x:0,y:0,width:245,height:36))
        setAccessibilityElement(false)
        for (index,color) in FileMarkColor.allCases.enumerated() {
            let button=ColorChoiceButton(frame:NSRect(x:10+index*32,y:4,width:27,height:28))
            button.isBordered=false;button.imagePosition = .imageOnly;button.bezelStyle = .regularSquare;button.tag=index
            button.target=self;button.action=#selector(pressed(_:));button.toolTip=color.rawValue
            button.setAccessibilityLabel(color.rawValue+"标签");addSubview(button);buttons.append(button)
        }
        refresh()
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    @objc private func pressed(_ sender:NSButton) {toggle(FileMarkColor.allCases[sender.tag]);refresh()}
    private func refresh() {
        let values=selected()
        for (index,button) in buttons.enumerated() {
            let color=FileMarkColor.allCases[index],chosen=values.contains(color)
            button.markColor=color;button.chosen=chosen;button.needsDisplay=true
            button.setAccessibilityValue(chosen ? "已添加" : "未添加")
        }
    }
}

@MainActor final class NamedTagMenuView:NSView {
    private let fileTag:FileTag
    private let selected:()->Bool
    private let toggle:()->Void
    private let button=TagHoverButton()
    init(tag:FileTag,selected:@escaping ()->Bool,toggle:@escaping ()->Void) {
        self.fileTag=tag;self.selected=selected;self.toggle=toggle
        super.init(frame:NSRect(x:0,y:0,width:245,height:30));setAccessibilityElement(false)
        button.frame=NSRect(x:10,y:4,width:min(220,max(60,(tag.name as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:12)]).width+40)),height:22)
        button.isBordered=false;button.wantsLayer=true;button.layer?.cornerRadius=6
        button.layer?.backgroundColor=NSColor(tag.color.tagBackground()).cgColor
        button.layer?.borderColor=NSColor(tag.color.color).withAlphaComponent(0.45).cgColor;button.layer?.borderWidth=1
        button.font=NSFont.systemFont(ofSize:12,weight:.medium);button.contentTintColor = .labelColor
        button.target=self;button.action=#selector(pressed);button.setAccessibilityLabel("标签："+tag.name);addSubview(button);refresh()
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    @objc private func pressed() {toggle();refresh()}
    private func refresh() {button.attributedTitle=NSAttributedString(string:(selected() ? "✓ " : "")+fileTag.name,attributes:[.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:NSColor(fileTag.color.labelColor)]);button.setAccessibilityValue(selected() ? "已添加" : "未添加")}
}

struct TagManager:View {
    @ObservedObject var model:SearchLibrary
    let file:FileHit
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text("自定义标签").font(.headline);Spacer();Button("完成") {dismiss()}}
            Text("修改名称或颜色会更新所有使用此标签的文件。").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(model.preferences.customTags ?? []) {tag in
                    HStack {
                        Button {model.toggleTag(file,tag)} label: {HStack {Image(systemName:model.hasTag(file,tag) ? "checkmark.circle.fill" : "circle");TagBadge(tag:tag)}}.buttonStyle(.plain)
                        Spacer();Button("编辑") {model.chooseEditTag(tag)}
                        Button("删除") {model.deleteTag(tag)}
                    }.padding(.vertical,4)
                }
            }.frame(minHeight:160)
            Button {model.chooseCustomTag(file)} label: {Label("新建标签…",systemImage:"plus")}
        }.padding(20).frame(width:420,height:340)
    }
}

struct TagRegionKey:PreferenceKey {
    static let defaultValue:[String:[String:CGRect]]=[:]
    static func reduce(value:inout [String:[String:CGRect]],nextValue:()->[String:[String:CGRect]]) {
        for (file,regions) in nextValue() {value[file,default:[:]].merge(regions,uniquingKeysWith:{$1})}
    }
}
@MainActor final class TagHoverButton:NSButton {
    private var area:NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas();if let area {removeTrackingArea(area)}
        let next=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil);area=next;addTrackingArea(next)
    }
    override func mouseEntered(with event:NSEvent) {alphaValue=0.7}
    override func mouseExited(with event:NSEvent) {alphaValue=1}
}

@MainActor final class ColorChoiceButton:NSButton {
    var markColor:FileMarkColor = .red
    var chosen=false
    private var hovering=false,area:NSTrackingArea?
    override func updateTrackingAreas() {super.updateTrackingAreas();guard area == nil else {return};let next=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil);area=next;addTrackingArea(next)}
    override func mouseEntered(with event:NSEvent) {hovering=true;needsDisplay=true}
    override func mouseExited(with event:NSEvent) {hovering=false;needsDisplay=true}
    override func draw(_ dirtyRect:NSRect) {
        let diameter:CGFloat=hovering ? 25 : 18,rect=NSRect(x:(bounds.width-diameter)/2,y:(bounds.height-diameter)/2,width:diameter,height:diameter)
        let path=NSBezierPath(ovalIn:rect),color=NSColor(markColor.color)
        color.withAlphaComponent(0.72).setFill();path.fill();color.setStroke();path.lineWidth=1.1;path.stroke()
        let symbol=hovering ? (chosen ? "−" : "+") : chosen ? "✓" : ""
        if !symbol.isEmpty {let text=symbol as NSString,attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:hovering ? 17 : 11,weight:.semibold),.foregroundColor:NSColor.white];let size=text.size(withAttributes:attrs);text.draw(at:NSPoint(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2),withAttributes:attrs)}
    }
}
