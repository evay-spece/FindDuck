import SwiftUI

@MainActor final class HomeReorderState:ObservableObject {
    @Published private(set) var draggedID:UUID?
    @Published private(set) var preview:[UUID]=[]
    private(set) var group:Int?
    private var frames:[UUID:()->CGRect?]=[:]
    private var slots:[(index:Int,frame:CGRect)]=[]
    private var original:[UUID]=[]

    func record(_ id:UUID,frame:CGRect) {record(id,provider:{frame})}
    func record(_ id:UUID,provider:@escaping ()->CGRect?) {frames[id]=provider}
    func begin(_ id:UUID,items:[HomeShortcut]) {
        guard draggedID == nil,let item=items.first(where:{$0.id == id}) else {return}
        let peers=items.filter {$0.group == item.group}
        slots=peers.enumerated().compactMap {index,item in
            guard let frame=frames[item.id]?(),!frame.isEmpty else {return nil};return (index,frame)
        }
        guard slots.contains(where:{peers[$0.index].id == id}) else {return}
        original=peers.map(\.id)
        group=item.group;preview=original;draggedID=id
    }
    func update(_ point:CGPoint) {
        guard let id=draggedID,!slots.isEmpty else {return}
        let area=slots.dropFirst().reduce(slots[0].frame) {$0.union($1.frame)}.insetBy(dx:-8,dy:-8)
        guard area.contains(point) else {if preview != original {preview=original};return}
        guard let target=slots.min(by:{distance(point,$0.frame)<distance(point,$1.frame)}) else {return}
        var order=original.filter {$0 != id};order.insert(id,at:target.index)
        if order != preview {preview=order}
    }
    private func distance(_ p:CGPoint,_ r:CGRect)->CGFloat {pow(p.x-r.midX,2)+pow(p.y-r.midY,2)}
    func entries(_ items:[HomeShortcut],group:Int)->[HomeShortcut] {
        let peers=items.filter {$0.group == group}
        guard self.group == group,draggedID != nil,Set(peers.map(\.id)) == Set(preview) else {return peers}
        let lookup=Dictionary(uniqueKeysWithValues:peers.map {($0.id,$0)})
        return preview.compactMap {lookup[$0]}
    }
    func accepts(_ id:UUID,group:Int)->Bool {draggedID == id && self.group == group}
    func commit(to home:HomeLibrary) {
        if let group,draggedID != nil {home.reorder(group:group,ids:preview)}
        end()
    }
    func end() {draggedID=nil;group=nil;preview=[];original=[];slots=[]}
}
