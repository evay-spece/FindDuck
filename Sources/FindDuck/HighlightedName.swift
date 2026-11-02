import SwiftUI
import AppKit
import CoreText

enum KeywordHighlights {
    static func ranges(_ name:String,query:String)->[NSRange] {
        var result:[NSRange]=[]
        for term in query.split(whereSeparator:{$0.isWhitespace}).map(String.init) {
            var cursor=name.startIndex
            while cursor<name.endIndex,let r=name.range(of:term,options:[.caseInsensitive,.diacriticInsensitive],range:cursor..<name.endIndex) {result.append(NSRange(r,in:name));cursor=r.upperBound}
        }
        return result
    }
}
struct HighlightedName:NSViewRepresentable {
    let name:String
    let query:String
    func makeNSView(context:Context)->Surface {let view=Surface();view.setContentHuggingPriority(.defaultHigh,for:.horizontal);view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);return view}
    func updateNSView(_ view:Surface,context:Context) {if view.name != name || view.query != query {view.name=name;view.query=query;view.invalidateIntrinsicContentSize();view.needsDisplay=true};view.setAccessibilityLabel(name)}
    final class Surface:NSView {
        var name="",query=""
        private let font=NSFont.systemFont(ofSize:13,weight:.semibold)
        override var isFlipped:Bool {true}
        override var intrinsicContentSize:NSSize {NSSize(width:(name as NSString).size(withAttributes:[.font:font]).width+2,height:18)}
        override init(frame:NSRect) {super.init(frame:frame);setAccessibilityElement(true);setAccessibilityRole(.staticText)}
        required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
        override func draw(_ dirtyRect:NSRect) {
            guard !name.isEmpty else {return}
            let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
            let string=NSMutableAttributedString(string:name,attributes:[.font:font,.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph])
            let line=CTLineCreateWithAttributedString(string)
            let fullWidth=CGFloat(CTLineGetTypographicBounds(line,nil,nil,nil))
            let right=max(0,bounds.width-(fullWidth>bounds.width ? 13 : 0))
            for range in KeywordHighlights.ranges(name,query:query) {
                let start=CTLineGetOffsetForStringIndex(line,range.location,nil),end=CTLineGetOffsetForStringIndex(line,range.location+range.length,nil)
                let x=max(0,min(start,end)),width=min(right,max(start,end))-x
                guard width>0 else {continue}
                NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect:NSRect(x:x,y:1,width:width,height:16),xRadius:3,yRadius:3).fill()
                string.addAttribute(.foregroundColor,value:NSColor.controlAccentColor.blended(withFraction:0.25,of:.labelColor) ?? NSColor.controlAccentColor,range:range)
            }
            string.draw(in:NSRect(x:0,y:1,width:bounds.width,height:18))
        }
    }
}
