import SwiftUI
import AppKit

private typealias ViewState<Value> = SwiftUI.State<Value>

private struct WindowBridge: NSViewRepresentable {
    let ready: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { ready(window) } }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct SearchPanel: View {
    @ObservedObject var model: SearchLibrary
    @ObservedObject var hotKeys: HotKeyManager
    @ObservedObject var home:HomeLibrary
    @StateObject private var categoryOrder = CategoryOrder()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ViewState private var selected: String? = nil
    @ViewState private var hovering: String? = nil
    @ViewState private var hoveredTag:String?
    @ViewState private var tagRegions:[String:[String:CGRect]]=[:]
    @ViewState private var keyboardTarget:String? = nil
    @ViewState private var previewArmed=false
    @ViewState private var showTags=false
    @ViewState private var tagManagerFile:FileHit?
    @ViewState private var debounce: Task<Void, Never>? = nil
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "magnifyingglass").font(.system(size: 21, weight: .medium)).foregroundStyle(.secondary)
                if let title=model.scopeTitle {
                    HStack(spacing:7) {
                        Image(systemName:"folder.fill").foregroundStyle(Color.accentColor)
                        Text(title).lineLimit(1).truncationMode(.middle)
                        Button {model.clearScope();hotKeys.focusSearchInput()} label: {Image(systemName:"xmark").font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)}
                            .buttonStyle(.plain).help("清除搜索范围").accessibilityLabel("清除搜索范围")
                    }.font(.system(size:20,weight:.medium)).padding(.horizontal,10).padding(.vertical,5)
                        .background(Color.primary.opacity(0.07),in:RoundedRectangle(cornerRadius:10))
                        .fixedSize(horizontal:true,vertical:true)
                        .help(model.directoryScope?.path ?? title).accessibilityElement(children:.contain).accessibilityLabel("搜索范围："+title)
                }
                PanelSearchField(text: $model.query, manager: hotKeys, onSubmit: { openSelection(reveal: $0) }, onMove: { moveSelection($0) }, onDeleteScope: {guard model.scopeTitle != nil else {return false};model.clearScope();return true}, onEscape: escapeSearch,onPreview:previewSelection)
                    .frame(height: 30).help("关键词输入框")
                if !model.query.isEmpty {
                    Button { model.query = ""; hotKeys.focusSearchInput() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }.buttonStyle(.plain).help("关键词清除按钮")
                }
                if model.isSearching || model.refreshingQuick { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 24).padding(.vertical, 22)
            if let value=DuckCalculator.evaluate(model.query) {
                Button {NSPasteboard.general.clearContents();NSPasteboard.general.setString(value,forType:.string)} label: {HStack {Image(systemName:"equal.circle");Text(value).font(.system(size:24,weight:.medium)).monospacedDigit();Spacer();Text("回车复制结果").font(.caption).foregroundStyle(.secondary)}.padding(.horizontal,24).padding(.vertical,12)}.buttonStyle(.plain)
            }
            Divider().opacity(0.55)
            HStack(spacing:12) {
                Group {
                    ScrollView(.horizontal) {
                        HStack(spacing:10) {
                            Menu {
                                if model.searchHistory.isEmpty {Text("暂无历史搜索")}
                                ForEach(model.searchHistory,id:\.self) {term in Button(term) {model.recallSearch(term);hotKeys.focusSearchInput()}}
                                if !model.searchHistory.isEmpty {Divider();Button("清空历史搜索") {model.clearSearchHistory()}}
                            } label: {Label("历史搜索",systemImage:"clock.arrow.circlepath").font(.system(size:12)).padding(.horizontal,12).padding(.vertical,6).background(Color.primary.opacity(0.055),in:Capsule())}
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("历史搜索")
                            quickEntry("今天微信接收到的文件", scope: .wechat)
                            quickEntry("今天下载的文件", scope: .downloads)
                            quickEntry("最近打开文件", scope: .recent).help("仅保留最近50个文件，可在其中继续筛选")
                            scopeEntry("共享盘",active:model.scopeTitle == "共享盘" && model.directoryScope == nil) {model.activateShared()}
                            ForEach(model.directoryShortcuts,id:\.self) {url in
                                scopeEntry(url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent,active:model.directoryScope == url) {model.activateDirectory(url)}
                                    .help(url.path).contextMenu {Button("移除快捷入口") {model.removeDirectoryShortcut(url)}}
                            }
                            Button {model.chooseDirectoryShortcut();hotKeys.focusSearchInput()} label: {Label("增加目录",systemImage:"plus")}
                                .buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal,8).accessibilityLabel("增加目录")
                        }
                    }.scrollIndicators(.hidden).frame(height:32)
                }
                Spacer()
            }.font(.system(size:11)).padding(.horizontal,20).padding(.vertical,10)
            tagFilters
            if !model.isHome {
            HStack(spacing: 5) {
                ForEach(categoryOrder.categories) { category in
                    Button { model.category = category; hotKeys.focusSearchInput() } label: {
                        Text(category.rawValue).font(.system(size: 12, weight: model.category == category ? .semibold : .regular))
                            .frame(minWidth:54,minHeight:34).padding(.horizontal,4).contentShape(Capsule())
                            .foregroundStyle(model.category == category ? Color.accentColor : Color.secondary)
                            .background(model.category == category ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
                    }.buttonStyle(.plain)
                    .help("类型筛选栏 · 拖动可调整分类顺序")
                    .overlay(Capsule().stroke(categoryOrder.dropTarget == category ? Color.accentColor : .clear, lineWidth: 1))
                    .onDrag { NSItemProvider(object: ("findduck-category:" + category.rawValue) as NSString) }
                    .dropDestination(for: String.self) { values, _ in
                        withAnimation(.easeInOut(duration: 0.18)) { categoryOrder.drop(values, on: category) }
                    } isTargeted: { targeted in
                        if targeted { categoryOrder.dropTarget = category }
                        else if categoryOrder.dropTarget == category { categoryOrder.dropTarget = nil }
                    }
                }
                Spacer(minLength: 8)
                Menu {
                    ForEach(ResultSort.allCases) {sort in
                        Button {model.resultSort=sort;hotKeys.focusSearchInput()} label: {
                            if model.resultSort == sort {Label(sort.rawValue,systemImage:"checkmark")} else {Text(sort.rawValue)}
                        }
                    }
                } label: {
                    HStack(spacing: 4) { Text(model.resultSort.rawValue); Image(systemName: "arrow.up.arrow.down") }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("排序菜单").accessibilityLabel("排序："+model.resultSort.rawValue)
            }.padding(.horizontal, 14).padding(.vertical, 10)
            }
            if !model.quickRefreshStatus.isEmpty {Text(model.quickRefreshStatus).font(.caption).foregroundStyle(.secondary).padding(.horizontal,20)}
            if !model.deepStatus.isEmpty {Text(model.deepStatus).font(.caption).foregroundStyle(.secondary).padding(.horizontal,20)}
            if !categoryOrder.error.isEmpty {Text(categoryOrder.error).font(.caption).foregroundStyle(.red)}
            if !model.status.isEmpty {Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal,20)}
            if model.isHome {
                HomePanel(home:home,model:model,hotKeys:hotKeys).frame(maxWidth:.infinity,maxHeight:.infinity)
            } else if model.hits.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scroll in
                    List {
                        ForEach(model.hits) { file in
                            resultRow(file)
                                .id(file.id)
                                .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                        if model.hasMoreResults {
                            Button("继续加载（已显示 \(model.hits.count) / \(model.resultCount)）") { model.loadMoreResults() }
                                .frame(maxWidth:.infinity).padding(.vertical,8).disabled(model.isSearching)
                        }
                    }.listStyle(.plain).scrollContentBackground(.hidden)
                        .onChange(of: keyboardTarget) { _, id in if let id { scroll.scrollTo(id) } }
                }
            }

        }
        .background(Color(nsColor: .textBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 860, minHeight: 500)
        .background(WindowBridge { window in
            window.styleMask.insert([.titled, .fullSizeContentView])
            window.isOpaque = false
            window.backgroundColor = .textBackgroundColor
            window.hasShadow = true
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(kind)?.isHidden = true }
            hotKeys.searchWindow = window
            if let screen=window.screen ?? NSScreen.main {
                let visible=screen.visibleFrame
                window.setContentSize(NSSize(width:min(920,visible.width-40),height:min(580,visible.height-60)))
                window.center()
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps:true)
        })
        .sheet(item:$tagManagerFile) {file in TagManager(model:model,file:file)}
        .onAppear {
            hotKeys.openSearch = { openWindow(id: "search") }
            hotKeys.prepareSearch = {elapsed in if HomeLibrary.shouldShowHome(elapsed:elapsed,resumeWindow:home.resumeWindowSeconds) {model.showHome()}}
            hotKeys.openSettings = { openSettings() }
        }
        .onChange(of: model.query) { _, query in
            previewArmed=false
            debounce?.cancel()
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { if model.isHome { model.clearResults(); selected = nil } else if !model.isSearching { model.search() }; return }
            debounce = Task {
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                guard !Task.isCancelled else { return }; model.search()
            }
        }
        .onChange(of: model.hits) { _, hits in
            if !hits.contains(where: { $0.id == selected }) { selected = hits.first?.id }
        }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.return, phases: .down) { press in
            if press.modifiers.contains(.command) { openSelection(reveal: true); return .handled }
            return .ignored
        }
        .onExitCommand {escapeSearch()}
    }
    private func quickEntry(_ title: String, scope: QuickScope) -> some View {
        let active = model.quickScope == scope && model.directoryScope == nil
        return Button { model.activateQuick(scope); hotKeys.focusSearchInput() } label: {
            Label(title, systemImage: "magnifyingglass")
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .background(active ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.055), in: Capsule())
        }.buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
    private func scopeEntry(_ title:String,active:Bool,action:@escaping ()->Void) -> some View {
        Button {action();hotKeys.focusSearchInput()} label: {
            Label(title,systemImage:"magnifyingglass").font(.system(size:12,weight:active ? .semibold : .regular))
                .padding(.horizontal,12).padding(.vertical,6)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .background(active ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.055),in:Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(active ? [.isSelected] : [])
    }
    private var footer: String {
        if model.isIndexing { return "正在建立索引 · 已扫描 \(model.scanned) 条记录" }
        if model.connectionUnavailable { return model.query.isEmpty ? "离线索引 · \(model.indexedFileCount) 个文件" : "\(model.resultCount) 个结果 · 离线索引" }
        if !model.hasIndex { return "请在设置中添加搜索文件夹" }
        if !model.query.isEmpty || model.scopeTitle != nil { return "\(model.resultCount) 个结果 · \(model.scopeTitle ?? model.sourceFilter.rawValue)" }
        return "已索引 \(model.indexedFileCount) 个文件"
    }
    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: model.query.isEmpty ? "magnifyingglass" : "doc.text.magnifyingglass")
                .font(.system(size: 38, weight: .light)).foregroundStyle(.tertiary)
            Text(model.isSearching ? "正在搜索…" : (model.quickScope == .downloads || model.quickScope == .wechat) ? "今天没有找到符合条件的文件" : !model.hasIndex && !model.sources.isEmpty ? "正在载入或建立索引…" : !model.hasIndex ? "添加本地或共享盘文件夹" : model.quickScope == .recent ? "暂无匹配的最近打开记录" : model.isHome ? "输入文件名开始搜索" : "没有找到匹配结果")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            if !model.hasIndex {
                SettingsLink { Text("打开设置") }.buttonStyle(.bordered)
            } else if !model.query.isEmpty {
                Text("新文件会在后台目录检查后收录，可在设置中查看进度。")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
    }
    private func resultRow(_ file: FileHit) -> some View {
        return HStack(spacing: 13) {
            Image(nsImage: FileIcons.shared.icon(for: file))
                .resizable().interpolation(.high).scaledToFit()
                .frame(width: 30, height: 32).padding(.horizontal,2)
                .accessibilityLabel(file.isDirectory ? "文件夹" : "默认打开软件图标")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing:6) {
                    Text(DisplayPath.highlighted(file.name,query:model.query)).font(.system(size:13,weight:.semibold)).lineLimit(1)
                    ForEach(model.tags(file)) {tag in trackedTag(tag,file:file)}
                    if let note=model.preferences.fileNotes?[file.id],!note.isEmpty {trackedTag(FileTag(id:"note",name:note,color:.gray),file:file)}
                }
                HStack(spacing:4) {Image(systemName:model.sources.contains(where:{$0.kind == .shared && DuckRules.under(file.url,$0.url)}) ? "network" : file.url.path.contains("/msg/file/") ? "bubble.left.and.bubble.right" : "internaldrive");Text(DisplayPath.parent(file.url)).lineLimit(1).truncationMode(.middle)}.font(.system(size:11)).foregroundStyle(.secondary).help(file.url.deletingLastPathComponent().path)
            }
            Spacer(minLength: 16)
            VStack(alignment:.trailing,spacing:4) {
                Text(file.modified.map {$0.formatted(date:.numeric,time:.shortened)} ?? "修改时间待更新").font(.system(size:11)).foregroundStyle(.secondary)
            Text(file.isDirectory ? "文件夹" : file.url.pathExtension.isEmpty ? "文件" : file.url.pathExtension.uppercased())
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(minWidth: 40, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(selected == file.id ? Color.accentColor.opacity(0.30) : hovering == file.id ? Color.accentColor.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .coordinateSpace(name:file.id)
        .onPreferenceChange(TagRegionKey.self) {value in if tagRegions[file.id] != value[file.id] {tagRegions[file.id]=value[file.id]}}
        .contentShape(Rectangle())
        .overlay {
            ImmediateResultClick(select:{previewArmed=true;guard selected != file.id else {return};var transaction=Transaction();transaction.disablesAnimations=true;withTransaction(transaction) {selected=file.id}},hover:{point in
                if let point {hovering=file.id;let match=tagRegions[file.id]?.first(where:{$0.value.contains(point)}).map {file.id+"|"+$0.key};if hoveredTag != match {hoveredTag=match}}
                else if hovering == file.id {hovering=nil;hoveredTag=nil}
            },open:{reveal in if reveal {model.reveal(file)} else {model.open(file)}},menu:{fileMenu(file)})
        }
    }
    private func trackedTag(_ tag:FileTag,file:FileHit)->some View {
        TagBadge(tag:tag,highlighted:hoveredTag == file.id+"|"+tag.id)
            .background(GeometryReader {proxy in Color.clear.preference(key:TagRegionKey.self,value:[file.id:[tag.id:proxy.frame(in:.named(file.id))]])})
    }
    @ViewBuilder private var selectedActions:some View {
        if let file=model.hits.first(where:{$0.id == selected}) {
            HStack(spacing:12) {
                Button {showTags.toggle()} label: {Image(systemName:"tag")}
                    .buttonStyle(.plain).help("文件标签").accessibilityLabel("文件标签")
                    .popover(isPresented:$showTags) {
                        FileTagEditor(model:model,file:file,create:{showTags=false;DispatchQueue.main.async {tagManagerFile=file}})
                    }
                Button {model.requestTrash(file)} label: {Image(systemName:"trash")}.buttonStyle(.plain).help("移到废纸篓").accessibilityLabel("删除选中文件")
            }
        }
    }
    private func fileMenu(_ file:FileHit)->NSMenu {
        let menu=NSMenu()
        menu.addItem(ResultMenus.item("打开") {model.open(file)})
        menu.addItem(ResultMenus.item("在 Finder 中显示") {model.reveal(file)})
        menu.addItem(ResultMenus.item("复制路径") {NSPasteboard.general.clearContents();NSPasteboard.general.setString(file.url.path,forType:.string)})
        menu.addItem(.separator())
        let palette=NSMenuItem();palette.view=TagColorPalette(selected:{Set(model.tags(file).filter {$0.name.isEmpty}.map(\.color))},toggle:{model.toggleTag(file,FileTag.builtin($0))});menu.addItem(palette)
        for tag in model.preferences.customTags ?? [] {
            let item=NSMenuItem();item.view=NamedTagMenuView(tag:tag,selected:{model.hasTag(file,tag)},toggle:{model.toggleTag(file,tag)});menu.addItem(item)
        }
        menu.addItem(ResultMenus.item("自定义标签…") {tagManagerFile=file})
        menu.addItem(ResultMenus.item("备注…") {model.chooseNote(file)})
        menu.addItem(ResultMenus.item("屏蔽此文件") {model.blockFile(file)})
        menu.addItem(ResultMenus.item("快速预览") {FilePreview.shared.show(file)})
        menu.addItem(.separator())
        let trash=ResultMenus.item("移到废纸篓…") {model.requestTrash(file)};trash.image=NSImage(systemSymbolName:"trash",accessibilityDescription:nil);menu.addItem(trash)
        return menu
    }
    @ViewBuilder private var tagFilters:some View {
        ScrollView(.horizontal) {
            HStack(spacing:8) {
                Button {model.tagFilter=model.tagFilter == "*" ? nil : "*";hotKeys.focusSearchInput()} label: {Text("所有标签").font(.system(size:12)).padding(.horizontal,12).frame(height:30).background(model.tagFilter == "*" ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.045),in:Capsule()).foregroundStyle(model.tagFilter == "*" ? Color.accentColor : .secondary)}.buttonStyle(.plain)
                ForEach(model.tagCatalog) {tag in
                    Button {model.tagFilter=model.tagFilter == tag.id ? nil : tag.id;hotKeys.focusSearchInput()} label: {HStack(spacing:5) {TagBadge(tag:tag);if model.tagFilter == tag.id {Image(systemName:"checkmark").font(.caption)}}.padding(.horizontal,8).frame(height:30).background(model.tagFilter == tag.id ? Color.accentColor.opacity(0.12) : Color.clear,in:Capsule()).contentShape(Capsule())}.buttonStyle(.plain).help(tag.displayName)
                }
            }
        }.scrollIndicators(.hidden).frame(height:32).padding(.horizontal,20).padding(.bottom,6)
    }
    private func previewSelection()->Bool {guard previewArmed || model.query.isEmpty else {return false};guard let file=model.hits.first(where:{$0.id == selected}) else {return false};FilePreview.shared.show(file);return true}
    private func escapeSearch() {if model.consumeEscape() {hotKeys.focusSearchInput()} else {hotKeys.hideSearch()}}
    private func moveSelection(_ delta: Int) {
        previewArmed=true
        guard !model.hits.isEmpty else { return }
        let current = model.hits.firstIndex { $0.id == selected } ?? -1
        selected = model.hits[min(max(current + delta, 0), model.hits.count - 1)].id
        keyboardTarget=selected
    }
    private func openSelection(reveal: Bool) {
        if !reveal,let value=DuckCalculator.evaluate(model.query) {NSPasteboard.general.clearContents();NSPasteboard.general.setString(value,forType:.string);return}
        guard let file = model.hits.first(where: { $0.id == selected }) ?? model.hits.first else { model.search(); return }
        if reveal { model.reveal(file) } else { model.open(file) }
    }
}

struct SearchSettings: View {
    @ObservedObject var model: SearchLibrary
    @ObservedObject var hotKeys: HotKeyManager
    @ObservedObject var home:HomeLibrary
    @AppStorage("findduckDeveloperEntryVisibleV1") private var developerEntryVisible = false
    @ViewState private var selectedSettingsTab = "locations"
    var body: some View {
        TabView(selection: $selectedSettingsTab) {
            connection.tabItem { Label("搜索位置", systemImage: "externaldrive.connected.to.line.below") }.tag("locations")
            searchOptions.tabItem {Label("搜索",systemImage:"magnifyingglass")}.tag("search")
            indexing.tabItem { Label("索引", systemImage: "list.bullet.rectangle") }.tag("indexing")
            exclusions.tabItem {Label("黑名单",systemImage:"folder.badge.minus")}.tag("exclusions")
            keyboard.tabItem { Label("快捷键", systemImage: "keyboard") }.tag("keyboard")
            about.tabItem { Label("关于", systemImage: "info.circle") }.tag("about")
            if developerEntryVisible {
                developer.tabItem { Label("开发者", systemImage: "hammer") }.tag("developer")
            }
        }.padding(18).frame(width: 610, height: 440)
            .onDisappear { hotKeys.cancelRecording() }
    }
    private var connection: some View {
        Form {
            Section("搜索位置") {
                ForEach(model.sources) { source in
                    HStack(alignment: .top) {
                        Image(systemName: source.kind == .local ? "internaldrive" : "network")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.url.lastPathComponent).fontWeight(.medium)
                            Text(source.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(model.summary(source)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("类型", selection: Binding(get: { source.kind }, set: { model.setKind(source, $0) })) {
                            ForEach(SourceKind.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 85)
                        Button("移除") { model.remove(source) }.help("只移出搜索范围，不删除文件")
                    }
                }
                HStack {
                    Button("完成磁盘授权") { model.diskAuthorization() }
                    Button("选择已授权磁盘…") { model.chooseAuthorizedDisk() }
                    Button("添加共享盘文件夹…") { model.chooseFolder(kind: .shared) }
                }
                Text("仅搜索已添加的位置；移除不会删除文件。共享盘先在 Finder 连接，再从上方添加。微信文件位置自动识别。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private var searchOptions:some View {
        Form {
            Section("主页") {
                Picker("短时间保留搜索",selection:$home.resumeWindowSeconds) {
                    Text("30 秒").tag(30.0);Text("2 分钟").tag(120.0);Text("5 分钟").tag(300.0);Text("10 分钟").tag(600.0)
                }
                Text("在这段时间内再次呼出会保留上次搜索，超过后显示主页。主页入口可自行添加、重命名、移除和调整顺序。").font(.caption).foregroundStyle(.secondary)
            }
            Section("搜索过滤") {
                Toggle("不搜索疑似系统文件",isOn:Binding(get:{model.preferences.suppressNoise},set:{model.toggleNoise($0)}))
                Text("隐藏系统路径、长十六进制、UUID 及部分长随机名称；关闭后可查找被误判的文件。").font(.caption).foregroundStyle(.secondary)
            }
            Section("共享盘深度搜索") {
                TextField("关键词",text:$model.query)
                Button(model.deepSearching ? "停止深度搜索" : "开始深度搜索") {model.deepSearch()}
                Text("直接遍历已添加的共享盘目录查找文件名。目录范围仍生效，搜索期间可停止。").font(.caption).foregroundStyle(.secondary)
                if !model.deepStatus.isEmpty {Text(model.deepStatus).font(.caption).foregroundStyle(.secondary)}
            }
            Section("文件操作") {Text("标签只保存在找鸭，支持同一文件添加多个颜色和文字标签。删除使用废纸篓；不支持废纸篓的磁盘不会改用永久删除。").font(.caption).foregroundStyle(.secondary)}
        }.formStyle(.grouped)
    }
    private var indexing: some View {
        Form {
            Section("文件名索引") {
                Text(model.indexSummary).foregroundStyle(.secondary)
                Toggle("自动更新索引", isOn: $model.autoUpdate)
                Text("本地由 Oil Find 核心监听文件变化，并在重启后补齐历史事件；共享盘按目录分批检查，变化发现存在延迟。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.isIndexing {
                    HStack { ProgressView().controlSize(.small); Text("已扫描 \(model.scanned) 个文件 / \(model.scannedDirectories) 个目录"); Spacer(); Button("停止") { model.cancelIndex() } }
                } else {
                    Button(model.hasIndex ? "立即完整核对" : "建立文件名索引") { model.buildIndex() }.disabled(model.folder == nil)
                }
            }
            Section("后台状态") {
                Text(model.indexStatus.isEmpty ? "等待添加搜索位置。" : model.indexStatus).foregroundStyle(.secondary)
                if !model.coverage.isEmpty { Text(model.coverage).font(.caption).foregroundStyle(.secondary) }
            }
            Section { Text("仅索引文件名和路径，保存在此 Mac。默认跳过隐藏文件、符号链接及不必要的本地目录；应用和文档包仅收录本身。").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped)
    }
    private var exclusions: some View {
        Form {
            Section("不搜索以下文件夹及其子目录") {
                if model.preferences.blacklist.isEmpty { Text("暂无自定义黑名单").foregroundStyle(.secondary) }
                ForEach(model.preferences.blacklist,id:\.path) {url in
                    HStack {Text(url.path).font(.caption).textSelection(.enabled);Spacer();Button("移出黑名单") {model.removeBlacklist(url)}}
                }
                Button("添加黑名单文件夹…") {model.chooseBlacklist()}
                Text("管理你自行排除的文件夹及其子目录。只影响扫描与搜索，不会删除原文件。").font(.caption).foregroundStyle(.secondary)
            }
            Section("屏蔽的文件") {
                ForEach(Array(model.preferences.blockedFiles ?? []).sorted(),id:\.self) {path in HStack {Text(path).font(.caption).lineLimit(2);Spacer();Button("取消屏蔽") {model.unblockFile(path)}}}
            }
            Section {Text("最近打开排序结合 macOS 已记录的最近使用时间与找鸭成功打开的记录。系统未记录或未索引的文件无法取得使用时间。").font(.caption).foregroundStyle(.secondary)}
        }.formStyle(.grouped)
    }
    private var about: some View {
        ScrollView {
            VStack(spacing: 14) {
                DeveloperUnlockLogo { developerEntryVisible = true }.frame(width: 72, height: 72)
                Text("找鸭").font(.system(size: 24, weight: .semibold))
                Text("本地与共享盘文件搜索").font(.callout).foregroundStyle(.secondary)
                Text("版本 \(appVersion) · 构建 \(appBuild)").font(.caption).foregroundStyle(.secondary)
                Text("本地索引与搜索基于 Oil Find 开源核心（MIT）").font(.caption).foregroundStyle(.secondary)
                Button("界面组件说明") {if let url=Bundle.main.url(forResource:"找鸭-界面组件说明",withExtension:"txt") {NSWorkspace.shared.open(url)}}
                Button("开源许可证") {if let url=Bundle.main.url(forResource:"OilFind-LICENSE",withExtension:"txt") {NSWorkspace.shared.open(url)}}
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("快速查找文件名，支持多位置索引、分类筛选、修改时间及最近打开排序。")
                    LabeledContent("当前快捷键", value: hotKeys.settings.enabled ? hotKeys.settings.display : "已停用")
                    LabeledContent("搜索范围", value: "\(model.sources.count) 个位置")
                    Text("索引和设置保存在这台 Mac，文件名搜索不上传文件内容。共享盘文件需连接后打开。").font(.caption).foregroundStyle(.secondary)
                    Text("索引保存位置").font(.caption.weight(.medium))
                    Text(indexStorage.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("打开索引文件夹") { NSWorkspace.shared.open(indexStorage) }
                        .disabled(!FileManager.default.fileExists(atPath: indexStorage.path))
                    Button("复制版本信息") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("找鸭 \(appVersion) (\(appBuild)) · \(ProcessInfo.processInfo.operatingSystemVersionString)", forType: .string)
                    }
                }.padding(.top, 3)
            }.padding(22)
        }
    }
    private var developer: some View {
        Form {
            Section("运行状态") {
                LabeledContent("版本", value: "\(appVersion)（\(appBuild)）")
                LabeledContent("本地内核",value:"OilFindCore（MIT）")
                LabeledContent("索引状态", value: model.isIndexing ? "正在扫描" : "空闲")
                LabeledContent("已索引文件", value: "\(model.indexedFileCount)")
                LabeledContent("本轮扫描", value: "\(model.scanned) 个文件 · \(model.scannedDirectories) 个目录")
                LabeledContent("自动更新", value: model.autoUpdate ? "已开启" : "已关闭")
                LabeledContent("全局快捷键", value: hotKeys.isRegistered ? "已注册" : "未注册")
                LabeledContent("黑名单", value: "用户 \(model.preferences.blacklist.count) 项 · 开发者 \(model.preferences.developerBlacklist?.count ?? 0) 项")
            }
            Section("本地索引范围") {
                Text("默认按 Oil Find 的范围规则跳过系统、资源库、依赖目录和包内部。微信接收目录、iCloud 和网盘文件保留。").font(.caption).foregroundStyle(.secondary)
                Toggle("扫描系统目录", isOn: localOption(\.indexSystemDirs))
                Toggle("扫描用户资源库", isOn: localOption(\.indexUserLibrary))
                Toggle("扫描开发依赖目录", isOn: localOption(\.indexDependencyDirs))
                Toggle("扫描应用和文档包内部", isOn: localOption(\.indexPackageContents))
                Text("调整后重新核对本地索引；两套黑名单仍优先生效。共享盘保持原扫描策略。").font(.caption).foregroundStyle(.secondary)
            }
            Section("开发者黑名单") {
                Text("与用户黑名单同时生效；隐藏开发者入口后仍继续排除这些文件夹及其子目录。").font(.caption).foregroundStyle(.secondary)
                ForEach(model.preferences.developerBlacklist ?? [], id: \.path) { url in
                    HStack {
                        Text(url.path).font(.caption).textSelection(.enabled)
                        Spacer()
                        Button("移除") { model.removeBlacklist(url, developer:true) }
                    }
                }
                Button("添加开发者黑名单文件夹…") { model.chooseBlacklist(developer:true) }
            }
            Section("本机诊断") {
                Text(model.indexStatus.isEmpty ? "暂无索引状态" : model.indexStatus).font(.caption).textSelection(.enabled)
                Button("复制诊断信息") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnosticText, forType: .string)
                }
                Text("诊断信息包含版本和运行状态，不包含文件名或搜索内容。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("隐藏开发者入口") {
                    selectedSettingsTab = "about"
                    developerEntryVisible = false
                }
            }
        }.formStyle(.grouped)
    }
    private func localOption(_ keyPath: WritableKeyPath<LocalIndexOptions,Bool>) -> Binding<Bool> {
        Binding(get: { (model.preferences.localIndexOptions ?? LocalIndexOptions())[keyPath:keyPath] },set: { enabled in
            var options=model.preferences.localIndexOptions ?? LocalIndexOptions()
            options[keyPath:keyPath]=enabled;model.setLocalOptions(options)
        })
    }
    private var diagnosticText: String {
        ["找鸭 \(appVersion)（\(appBuild)）", ProcessInfo.processInfo.operatingSystemVersionString,
         "索引中：\(model.isIndexing)；已索引：\(model.indexedFileCount)",
         "本轮扫描：\(model.scanned) 文件 / \(model.scannedDirectories) 目录",
         "搜索位置：\(model.sources.count)；用户黑名单：\(model.preferences.blacklist.count)；开发者黑名单：\(model.preferences.developerBlacklist?.count ?? 0)",
         "自动更新：\(model.autoUpdate)；快捷键注册：\(hotKeys.isRegistered)"].joined(separator: "\n")
    }
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知" }
    private var appBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知" }
    private var indexStorage: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.chenhuang.smbsearch/NameIndexes", isDirectory: true) }
    private var keyboard: some View {
        Form {
            Section("全局呼出搜索") {
                Toggle("启用全局快捷键", isOn: Binding(get: { hotKeys.settings.enabled }, set: { hotKeys.setEnabled($0) }))
                HStack {
                    Text("快捷键")
                    Spacer()
                    Button { hotKeys.beginRecording() } label: {
                        Text(hotKeys.isRecording ? "请按下组合键…" : hotKeys.settings.display)
                            .font(.system(size: 14, weight: .medium, design: .monospaced)).frame(minWidth: 150)
                    }.disabled(!hotKeys.settings.enabled)
                        .background(ShortcutRecorder(manager: hotKeys).frame(width: 1, height: 1))
                    Button("恢复默认") { hotKeys.restoreDefault() }
                }
                Text(hotKeys.message).font(.callout).foregroundStyle(hotKeys.hasError ? Color.red : Color.secondary)
            }
            Section {
                Text("点击快捷键后直接按下新组合键，按 Esc 取消。至少搭配 Control、Option 或 Command 中的一个键。")
                Text("在其他应用中也能呼出搜索并聚焦输入框。按 Esc 隐藏搜索窗口，找鸭继续常驻菜单栏；点击“退出找鸭”或按 ⌘Q 才会退出。")
            }.font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}
@MainActor final class SearchAppDelegate: NSObject, NSApplicationDelegate {
    weak var hotKeys: HotKeyManager?
    private var statusItem: NSStatusItem?
    weak var library:SearchLibrary?
    func applicationWillTerminate(_ notification:Notification) {library?.shutdown()}
    private var windowObserver: NSObjectProtocol?
    private func hideWindowControls(_ window:NSWindow) {
        guard window.title == "找鸭" || window.identifier?.rawValue == "search" else {return}
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for kind in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
            window.standardWindowButton(kind)?.superview?.isHidden = true
        }
    }
    private func installMenuBar() {
        let item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        item.button?.image = DuckMenuBarIcon.load()
        item.button?.toolTip="找鸭"
        let menu=NSMenu()
        for (title,action) in [("显示搜索",#selector(showSearch)),("设置…",#selector(showPreferences)),("退出找鸭",#selector(quitApp))] {
            let entry=NSMenuItem(title:title,action:action,keyEquivalent:"");entry.target=self;menu.addItem(entry)
        }
        item.menu=menu;statusItem=item
    }
    @objc func showPreferences() {NSApp.activate(ignoringOtherApps:true);hotKeys?.openSettings?()}
    @objc func quitApp() {NSApp.terminate(nil)}
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--verify-startup") {FileHandle.standardError.write(Data("DID_FINISH_LAUNCH\n".utf8))}
        NSApp.setActivationPolicy(.regular)
        if let url=Bundle.main.url(forResource:"RocketDuckEdge",withExtension:"icns"),let image=NSImage(contentsOf:url) {NSApp.applicationIconImage=image}
        installMenuBar()
        windowObserver = NotificationCenter.default.addObserver(forName:NSWindow.didBecomeKeyNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in for window in NSApp.windows {self?.hideWindowControls(window)} }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in self?.showSearch() }
        if CommandLine.arguments.contains("--verify-startup") {
            DispatchQueue.main.asyncAfter(deadline:.now()+2) {
                let windows=NSApp.windows.filter {$0.identifier?.rawValue == "search" || $0.title == "找鸭"}
                for window in windows {self.hideWindowControls(window)}
                print("NATIVE_WINDOW_FRAME=\(windows.allSatisfy {$0.styleMask.contains(.titled) && $0.hasShadow && !$0.isOpaque})")
                print("WINDOW_CONTROLS_HIDDEN=\(windows.allSatisfy {window in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton].allSatisfy {window.standardWindowButton($0)?.isHidden != false}})")
                print("MENU_BAR_CREATED=\(self.statusItem?.button != nil)")
                print("MENU_BAR_TEMPLATE=\(self.statusItem?.button?.image?.isTemplate == true)")
                print("MENU_BAR_LOGICAL_SIZE=\(self.statusItem?.button?.image?.size == NSSize(width:20,height:20))")
                print("MENU_BAR_REPRESENTATIONS=\(self.statusItem?.button?.image?.representations.count ?? 0)")
                print("STARTUP_WINDOW_COUNT=\(windows.count) VISIBLE=\(windows.contains {$0.isVisible}) KEY=\(windows.contains {$0.isKeyWindow})")
                fflush(stdout)
                self.hotKeys?.hideSearch()
                print("HIDDEN=\(windows.allSatisfy {!$0.isVisible})")
                print("MENU_BAR_AFTER_HIDE=\(self.statusItem?.button != nil)")
                print("HOTKEY_AFTER_HIDE=\(self.hotKeys?.isRegistered == true)")
                self.showSearch()
                print("RESHOWN=\(windows.contains {$0.isVisible})")
                windows.first?.close()
                DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
                    self.showSearch()
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                        let reopened=NSApp.windows.filter {$0.title == "找鸭" || $0.identifier?.rawValue == "search"}
                        print("REOPENED=\(reopened.contains {$0.isVisible}) VISIBLE_COUNT=\(reopened.filter {$0.isVisible}.count)")
                        fflush(stdout);NSApp.terminate(nil)
                    }
                }
            }
        }
    }
    @objc func showSearch() {
        if let hotKeys { hotKeys.invoke(); return }
        NSApp.activate(ignoringOtherApps:true)
        if let window=NSApp.windows.first(where: {$0.title == "找鸭" || $0.identifier?.rawValue == "search"}) {window.center();window.makeKeyAndOrderFront(nil)}
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool {if flag {return true};showSearch();return false}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct SMBSearchApp: App {
    @NSApplicationDelegateAdaptor(SearchAppDelegate.self) private var appDelegate
    @StateObject private var model = SearchLibrary()
    @StateObject private var hotKeys = HotKeyManager()
    @StateObject private var home = HomeLibrary()
    var body: some Scene {
        WindowGroup("找鸭", id: "search") { SearchPanel(model: model, hotKeys: hotKeys, home: home).onAppear { appDelegate.hotKeys = hotKeys; appDelegate.library = model; if CommandLine.arguments.contains("--verify-startup") {DispatchQueue.main.asyncAfter(deadline:.now()+0.7) {model.refreshRecents()}} } }
            .windowStyle(.hiddenTitleBar).defaultSize(width: 920, height: 580)
            .commands {
                CommandGroup(replacing: .newItem) { Button("显示搜索") { hotKeys.invoke() }.keyboardShortcut("f", modifiers: [.command, .shift]) }
            }
        Settings { SearchSettings(model: model, hotKeys: hotKeys, home: home) }
    }
}
