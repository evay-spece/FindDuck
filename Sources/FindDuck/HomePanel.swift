import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HomePanel:View {
    @ObservedObject var home:HomeLibrary
    @ObservedObject var model:SearchLibrary
    @ObservedObject var hotKeys:HotKeyManager
    @State private var tool:HomeTool?
    private let columns=[GridItem(.adaptive(minimum:135,maximum:175),spacing:12)]
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                HStack {
                    VStack(alignment:.leading,spacing:4) {
                        Text("常用").font(.system(size:22,weight:.semibold))
                        Text("软件、网站和个人快捷功能").font(.system(size:12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("添加软件…") {choose(.application)}
                        Button("添加网站…") {addWebsite()}
                        Button("添加文件夹…") {choose(.folder)}
                        Button("添加功能…") {addAction()}
                    } label: {Label("添加入口",systemImage:"plus")}.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("添加主页入口")
                }
                HStack(spacing:12) {
                    Button {tool = .snippets} label: {Label("快捷文本",systemImage:"text.quote")}
                    Button {tool = .rates} label: {Label("人民币汇率",systemImage:"yensign.arrow.circlepath")}
                    Button {tool = .world} label: {Label("世界时间",systemImage:"globe")}
                }.buttonStyle(.bordered)
                section("常用软件",group:0)
                section("常用网站",group:1)
                section("快捷功能",group:2)
                if !home.error.isEmpty {Text(home.error).font(.caption).foregroundStyle(.secondary)}
            }.padding(.horizontal,28).padding(.vertical,12)
        }.accessibilityLabel("找鸭主页").sheet(item:$tool) {tool in QuickToolsPanel(tool:tool)}
    }
    @ViewBuilder private func section(_ title:String,group:Int)->some View {
        VStack(alignment:.leading,spacing:10) {
            Text(title).font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary)
            let entries=home.items.filter {$0.group == group}
            if entries.isEmpty {
                HStack {Text(group == 1 ? "把常用网站放在这里" : "添加你常用的入口").font(.system(size:12)).foregroundStyle(.tertiary);Spacer();Button(group == 1 ? "添加网站" : "添加入口") {if group == 1 {addWebsite()} else {choose(group == 0 ? .application : .folder)}}.buttonStyle(.plain).font(.system(size:12)).foregroundStyle(Color.accentColor)}
                    .padding(14).background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:12))
            } else {
                LazyVGrid(columns:group == 0 ? [GridItem(.adaptive(minimum:78,maximum:100),spacing:14)] : columns,alignment:.leading,spacing:12) {
                    ForEach(entries) {item in
                        HomeTile(item:item,action:{launch(item)})
                            .onDrag {NSItemProvider(object:("findduck-home:"+item.id.uuidString) as NSString)}
                            .dropDestination(for:String.self) {values,_ in
                                guard let value=values.first,value.hasPrefix("findduck-home:"),let id=UUID(uuidString:String(value.dropFirst("findduck-home:".count))) else {return false}
                                home.move(id:id,to:item);return true
                            }
                            .contextMenu {
                                Button("打开") {launch(item)}
                                Button("重命名…") {rename(item)}
                                Button("前移") {home.move(item,by:-1)}
                                Button("后移") {home.move(item,by:1)}
                                Divider();Button("移除主页入口") {home.remove(item)}
                            }
                    }
                }
            }
        }
    }
    private func launch(_ item:HomeShortcut) {
        if item.kind == .action {
            guard let action=HomeAction(rawValue:item.target) else {return}
            switch action {
            case .downloads:model.activateQuick(.downloads)
            case .wechat:model.activateQuick(.wechat)
            case .recent:model.activateQuick(.recent)
            case .settings:hotKeys.openSettings?()
            case .desktop:model.activateDirectory(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
            }
            if action != .settings {hotKeys.focusSearchInput()};return
        }
        let url=item.kind == .website ? HomeLibrary.websiteURL(item.target) : URL(fileURLWithPath:item.target)
        guard let url else {return}
        if NSWorkspace.shared.open(url) {hotKeys.hideSearch()} else {model.status="无法打开："+item.title}
    }
    private func choose(_ kind:HomeKind) {
        let panel=NSOpenPanel();panel.allowsMultipleSelection=false;panel.canChooseDirectories=kind == .folder;panel.canChooseFiles=kind == .application
        panel.treatsFilePackagesAsDirectories=false;panel.prompt="添加到主页"
        if kind == .application {panel.directoryURL=URL(fileURLWithPath:"/Applications");panel.allowedContentTypes=[.applicationBundle]}
        if panel.runModal() == .OK,let url=panel.url {_=home.add(title:kind == .application ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent,kind:kind,target:url.path)}
    }
    private func addWebsite() {
        let alert=NSAlert();alert.messageText="添加常用网站";alert.addButton(withTitle:"添加");alert.addButton(withTitle:"取消")
        let name=NSTextField(frame:NSRect(x:0,y:44,width:330,height:24));name.placeholderString="网站名称";name.setAccessibilityLabel("网站名称")
        let url=NSTextField(frame:NSRect(x:0,y:8,width:330,height:24));url.placeholderString="https://";url.setAccessibilityLabel("网站网址")
        let view=NSView(frame:NSRect(x:0,y:0,width:330,height:76));view.addSubview(name);view.addSubview(url);name.nextKeyView=url;alert.accessoryView=view;alert.window.initialFirstResponder=name
        if alert.runModal() == .alertFirstButtonReturn {_=home.add(title:name.stringValue.isEmpty ? (HomeLibrary.websiteURL(url.stringValue)?.host ?? "网站") : name.stringValue,kind:.website,target:url.stringValue)}
    }
    private func addAction() {
        let alert=NSAlert();alert.messageText="添加快捷功能";alert.addButton(withTitle:"添加");alert.addButton(withTitle:"取消")
        let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:300,height:28));picker.addItems(withTitles:HomeAction.allCases.map(\.rawValue));alert.accessoryView=picker
        if alert.runModal() == .alertFirstButtonReturn,let title=picker.titleOfSelectedItem {_=home.add(title:title,kind:.action,target:title)}
    }
    private func rename(_ item:HomeShortcut) {
        let alert=NSAlert();alert.messageText="重命名主页入口";alert.addButton(withTitle:"保存");alert.addButton(withTitle:"取消")
        let field=NSTextField(frame:NSRect(x:0,y:0,width:300,height:26));field.stringValue=item.title;alert.accessoryView=field;alert.window.initialFirstResponder=field
        if alert.runModal() == .alertFirstButtonReturn {home.rename(item,title:field.stringValue)}
    }
}
private typealias HomeState<Value> = SwiftUI.State<Value>
private struct HomeTile:View {
    let item:HomeShortcut
    let action:()->Void
    @HomeState private var hovering=false
    var body:some View {
        Button(action:action) {
            Group {
                if item.kind == .application {
                    VStack(spacing:6) {Image(nsImage:NSWorkspace.shared.icon(forFile:item.target)).resizable().scaledToFit().frame(width:50,height:50);Text(item.title).font(.system(size:12)).lineLimit(1)}
                        .padding(8).frame(maxWidth:.infinity,minHeight:88).background(Color.primary.opacity(hovering ? 0.065 : 0),in:RoundedRectangle(cornerRadius:12))
                } else {
                    HStack(spacing:10) {
                        if item.kind == .folder {Image(nsImage:NSWorkspace.shared.icon(forFile:item.target)).resizable().scaledToFit().frame(width:30,height:30)}
                        else {Image(systemName:item.kind == .website ? "globe" : HomeAction(rawValue:item.target)?.symbol ?? "bolt").font(.system(size:22)).foregroundStyle(Color.accentColor).frame(width:30,height:30)}
                        Text(item.title).font(.system(size:12,weight:.medium)).lineLimit(2).multilineTextAlignment(.leading);Spacer(minLength:0)
                    }.padding(12).frame(maxWidth:.infinity,minHeight:56).background(Color.primary.opacity(hovering ? 0.075 : 0.035),in:RoundedRectangle(cornerRadius:12))
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).onHover {hovering=$0}.help(item.kind == .action ? item.title : item.target).accessibilityLabel("主页入口："+item.title)
    }
}
