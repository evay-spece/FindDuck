import AppKit
import SwiftUI

// A small arithmetic grammar; no script evaluation or external process is involved.
enum DuckCalculator {
    static func preview(_ text: String) -> (value: String, complete: Bool)? {
        if let value = evaluate(text) { return (value, true) }
        var prefix = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let operators = "+-*/^%×÷"
        guard let last = prefix.last, operators.contains(last) else { return nil }
        while let last = prefix.last, operators.contains(last) || last.isWhitespace { prefix.removeLast() }
        if let value = evaluate(prefix) { return (value, false) }
        if let amount = CurrencyMath.amount(prefix) { return (NSDecimalNumber(decimal: amount).stringValue, false) }
        return nil
    }

    static func evaluate(_ text:String)->String? {
        let raw=text.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"=",with:"").replacingOccurrences(of:"×",with:"*").replacingOccurrences(of:"÷",with:"/")
        guard raw.count <= 256,raw.contains(where:{"+-*/^%".contains($0)}),raw.allSatisfy({$0.isNumber || $0.isWhitespace || ".()+-*/^%".contains($0)}) else {return nil}
        var parser=Parser(chars:Array(raw.filter {!$0.isWhitespace}))
        guard let value=parser.expression(),parser.index == parser.chars.count,value.isFinite else {return nil}
        return String(format:"%.12g",value == 0 ? 0 : value)
    }
    private struct Parser {
        let chars:[Character];var index=0
        mutating func take(_ c:Character)->Bool {if index < chars.count,chars[index] == c {index += 1;return true};return false}
        mutating func expression()->Double? {
            guard var v=product() else {return nil}
            while index < chars.count {if take("+") {guard let b=product() else {return nil};v += b} else if take("-") {guard let b=product() else {return nil};v -= b} else {break}}
            return v
        }
        mutating func product()->Double? {
            guard var v=unary() else {return nil}
            while index < chars.count {if take("*") {guard let b=unary() else {return nil};v *= b} else if take("/") {guard let b=unary(),b != 0 else {return nil};v /= b} else {break}}
            return v
        }
        mutating func unary()->Double? {if take("+") {return unary()};if take("-") {return unary().map {-$0}};return power()}
        mutating func power()->Double? {guard var v=atom() else {return nil};while take("%") {v /= 100};if take("^") {guard let b=unary() else {return nil};v=pow(v,b)};return v}
        mutating func atom()->Double? {
            if take("(") {guard let v=expression(),take(")") else {return nil};return v}
            let start=index;while index < chars.count,chars[index].isNumber || chars[index] == "." {index += 1}
            guard index > start else {return nil};return Double(String(chars[start..<index]))
        }
    }
}
struct QuickText:Codable,Identifiable,Equatable {var id=UUID();var title:String;var text:String}
@MainActor final class QuickTextLibrary:ObservableObject {
    @Published private(set) var items:[QuickText]=[]
    @Published var error=""
    private let file:URL
    init(file:URL?=nil) {
        self.file=file ?? BiuStorage.directory.appendingPathComponent("quick-texts.json")
        if let data=try? Data(contentsOf:self.file),let values=try? JSONDecoder().decode([QuickText].self,from:data) {items=values}
    }
    @discardableResult
    func save(_ item: QuickText) -> Bool {
        var updated = items
        if let index = updated.firstIndex(where: { $0.id == item.id }) {
            updated[index] = item
        } else {
            updated.append(item)
        }
        return persist(updated)
    }

    func remove(_ item: QuickText) { _ = persist(items.filter { $0.id != item.id }) }

    private func persist(_ updated: [QuickText]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: file, options: .atomic)
            items = updated
            error = ""
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
enum HomeTool: String, Identifiable {
    case rates = "人民币汇率", world = "世界时间"
    var id: String { rawValue }
}

struct QuickToolsPanel: View {
    let tool: HomeTool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(tool.rawValue).font(.headline); Spacer(); Button("完成") { dismiss() } }
            switch tool {
            case .rates: ExchangeRatesView()
            case .world: WorldClockView()
            }
        }.padding(20).frame(width: 560, height: tool == .rates ? 560 : 500)
    }
}
struct QuickTextsView: View {
    @ObservedObject var model: QuickTextLibrary
    @State private var editing: QuickText?
    @State private var copied: UUID?
    @State private var hovered: UUID?
    @State private var selected: UUID?
    @State private var query = ""
    @FocusState private var listFocused: Bool

    private var matches: [QuickText] {
        guard !query.isEmpty else { return model.items }
        return model.items.filter { $0.title.localizedStandardContains(query) || $0.text.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("增加文本", systemImage: "plus") { editing = QuickText(title: "", text: "") }
                Spacer()
                TextField("搜索", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 140)
            }
            if matches.isEmpty {
                ContentUnavailableView(query.isEmpty ? "暂无快捷文本" : "没有找到匹配文本",
                                       systemImage: "text.quote")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                            row(item, number: index + 1)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .id(item.id)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($listFocused)
                    .defaultFocus($listFocused, true)
                    .onKeyPress(.upArrow) { moveSelection(-1, proxy: proxy) }
                    .onKeyPress(.downArrow) { moveSelection(1, proxy: proxy) }
                    .onKeyPress(.return, phases: .down) { _ in
                        guard let item = matches.first(where: { $0.id == selected }) else { return .ignored }
                        copy(item)
                        return .handled
                    }
                }
            }
            Text(model.error.isEmpty ? "↑↓ 选择 · 回车或双击复制" : model.error)
                .font(.caption).foregroundStyle(model.error.isEmpty ? Color.secondary : Color.red)
        }
        .onChange(of: query) { selected = nil }
        .sheet(item: $editing) { QuickTextEditor(item: $0, save: model.save) }
    }

    private func row(_ item: QuickText, number: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number.formatted()).monospacedDigit()
                .foregroundStyle(Color(red: 8.0 / 255, green: 88.0 / 255, blue: 240.0 / 255))
                .frame(minWidth: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(item.title, systemImage: "text.quote").lineLimit(1)
                    Spacer()
                    if copied == item.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("已复制") }
                    action("复制", icon: "doc.on.doc") { copy(item) }
                    action("编辑", icon: "pencil") { editing = item }
                    action("删除", icon: "trash") {
                        model.remove(item)
                        if selected == item.id { selected = nil }
                    }
                }
                Text(item.text).font(.system(size: 13)).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 12))
        .padding(8)
        .frame(height: 136, alignment: .topLeading)
        .background(selected == item.id || hovered == item.id ? FindDuckHighlight.selected : .clear,
                    in: RoundedRectangle(cornerRadius: 11))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? item.id : nil }
        .onTapGesture(count: 2) { copy(item) }
        .accessibilityAddTraits(selected == item.id ? .isSelected : [])
        .accessibilityAction(named: Text("复制")) { copy(item) }
    }

    private func action(_ title: String, icon: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }

    private func moveSelection(_ offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let items = matches
        guard !items.isEmpty else { return .ignored }
        let current = items.firstIndex { $0.id == selected } ?? (offset > 0 ? -1 : items.count)
        let id = items[min(max(current + offset, 0), items.count - 1)].id
        selected = id
        proxy.scrollTo(id)
        return .handled
    }

    private func copy(_ item: QuickText) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(item.text, forType: .string) {
            copied = item.id
            model.error = ""
        } else {
            model.error = "复制失败"
        }
    }
}
struct QuickTextEditor: View {
    @State var item: QuickText
    let save: (QuickText) -> Bool
    @State private var saveFailed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("名称", text: $item.title)
            TextEditor(text: $item.text).frame(height: 180)
            if saveFailed { Text("保存失败，请重试").foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") {
                    if save(item) { dismiss() } else { saveFailed = true }
                }
                .disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.text.isEmpty)
            }
        }.padding(20).frame(width: 400)
    }
}
struct ExchangeRate:Codable,Identifiable,Sendable {let date:String;let base:String;let quote:String;let rate:Double;var id:String {quote}}
enum ExchangeRates {
    static let address="https://api.frankfurter.dev/v2/rates?base=CNY&quotes=USD,EUR,JPY,GBP,HKD"
    static func load() async throws->[ExchangeRate] {
        let request=URLRequest(url:URL(string:address)!,timeoutInterval:20)
        let (data,response)=try await URLSession.shared.data(for:request)
        guard let response=response as? HTTPURLResponse,response.statusCode == 200 else {throw URLError(.badServerResponse)}
        let rates=try JSONDecoder().decode([ExchangeRate].self,from:data)
        guard !rates.isEmpty,rates.allSatisfy({$0.base == "CNY" && $0.rate.isFinite && $0.rate > 0}) else {throw URLError(.cannotParseResponse)}
        return rates
    }
}
enum CurrencyMath {
    static let codes=["CNY","USD","EUR","HKD","JPY","GBP"]
    static let names=["CNY":"人民币","USD":"美元","EUR":"欧元","HKD":"港币","JPY":"日元","GBP":"英镑"]
    static func amount(_ text:String)->Decimal? {
        let text=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard text.count<=40,text.range(of:"^[+-]?(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\\.[0-9]{0,8})?$",options:.regularExpression) != nil else {return nil}
        return Decimal(string:text.replacingOccurrences(of:",",with:""),locale:Locale(identifier:"en_US_POSIX"))
    }
    static func convert(_ amount:Decimal,from:String,to:String,rates:[ExchangeRate])->Decimal? {
        guard codes.contains(from),codes.contains(to),!amount.isNaN else {return nil}
        if from == to {return amount}
        func rate(_ code:String)->Decimal? {
            if code == "CNY" {return 1}
            guard let value=rates.first(where:{$0.base == "CNY" && $0.quote == code}),value.rate.isFinite,value.rate>0 else {return nil}
            return Decimal(string:String(value.rate),locale:Locale(identifier:"en_US_POSIX"))
        }
        guard let a=rate(from),let b=rate(to) else {return nil};let result=amount/a*b;return result.isNaN ? nil : result
    }
    static func formatted(_ value:Decimal)->String {let f=NumberFormatter();f.numberStyle = .decimal;f.minimumFractionDigits=2;f.maximumFractionDigits=4;return f.string(from:value as NSDecimalNumber) ?? "—"}
}
private struct ExchangeRatesView:View {
    @State private var rates:[ExchangeRate]=[]
    @State private var error=""
    @State private var loading=false
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {Text("参考汇率 · 以1单位货币换算").font(.caption).foregroundStyle(.secondary);Spacer();Button("刷新") {Task {await refresh()}}.disabled(loading);if loading {ProgressView().controlSize(.small)}}
            if !error.isEmpty {Text(error).font(.caption).foregroundStyle(.secondary)}
            VStack(alignment:.leading,spacing:9) {
                if let rate=rates.first(where:{$0.quote == "USD"}) {
                    HStack(spacing:12) {Text("人民币 CNY").frame(width:95,alignment:.leading);Text(rate.rate.formatted(.number.precision(.fractionLength(4)))+" 美元").monospacedDigit().frame(width:110,alignment:.leading);Text(rate.date).font(.caption).foregroundStyle(.secondary)}
                }
                ForEach(CurrencyMath.codes.filter {$0 != "CNY"},id:\.self) {code in
                    if let rate=rates.first(where:{$0.quote == code}) {
                        HStack(spacing:12) {Text((CurrencyMath.names[code] ?? code)+" "+code).frame(width:95,alignment:.leading);Text((1/rate.rate).formatted(.number.precision(.fractionLength(4)))+" 元").monospacedDigit().frame(width:110,alignment:.leading);Text(rate.date).font(.caption).foregroundStyle(.secondary)}
                    }
                }
            }.font(.system(size:13)).padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
            Divider();Text("金额换算").font(.system(size:13,weight:.semibold))
            CurrencyConversionRow(title:"第一行",source:"USD",target:"CNY",rates:rates)
            CurrencyConversionRow(title:"第二行",source:"CNY",target:"USD",rates:rates)
            Spacer(minLength:0)
            HStack {Link("来源：Frankfurter",destination:URL(string:"https://frankfurter.dev/")!);Text("每日参考值，以各行日期为准").foregroundStyle(.secondary)}.font(.caption)
        }.task {await refresh()}
    }
    private func refresh() async {loading=true;defer {loading=false};do {rates=try await ExchangeRates.load();error=""} catch {self.error=rates.isEmpty ? "汇率暂时无法获取，请检查网络后重试。" : "刷新失败，仍显示上次数据。"}}
}
private struct CurrencyConversionRow:View {
    let title:String
    let rates:[ExchangeRate]
    @State private var amount="100"
    @State private var source:String
    @State private var target:String
    init(title:String,source:String,target:String,rates:[ExchangeRate]) {
        self.title=title;self.rates=rates;_source=State(initialValue:source);_target=State(initialValue:target)
    }
    private var converted:Decimal? {CurrencyMath.amount(amount).flatMap {CurrencyMath.convert($0,from:source,to:target,rates:rates)}}
    var body:some View {
        VStack(alignment:.leading,spacing:7) {
            HStack(spacing:10) {
                TextField("金额",text:$amount).textFieldStyle(.roundedBorder).frame(width:100).accessibilityLabel(title+"换算金额")
                Picker("从",selection:$source) {ForEach(CurrencyMath.codes,id:\.self) {Text((CurrencyMath.names[$0] ?? $0)+" "+$0).tag($0)}}.labelsHidden().accessibilityLabel(title+"原币种")
                Image(systemName:"arrow.right").foregroundStyle(.secondary)
                Picker("到",selection:$target) {ForEach(CurrencyMath.codes,id:\.self) {Text((CurrencyMath.names[$0] ?? $0)+" "+$0).tag($0)}}.labelsHidden().accessibilityLabel(title+"目标币种")
            }
            HStack {Text("换算结果").font(.caption).foregroundStyle(.secondary);if let converted {Text(CurrencyMath.formatted(converted)+" "+target).font(.system(size:18,weight:.semibold)).monospacedDigit().textSelection(.enabled)} else {Text(CurrencyMath.amount(amount) == nil ? "请输入有效金额" : "等待参考汇率").font(.caption).foregroundStyle(.secondary)}}
        }.padding(10).background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:10))
    }
}
struct ClockZone:Codable,Identifiable,Equatable {let name:String;let zone:String;var id:String {name+"|"+zone}}
enum WorldTimes {
    static let zones=[ClockZone(name:"北京",zone:"Asia/Shanghai"),ClockZone(name:"东京",zone:"Asia/Tokyo"),ClockZone(name:"新加坡",zone:"Asia/Singapore"),ClockZone(name:"伦敦",zone:"Europe/London"),ClockZone(name:"巴黎",zone:"Europe/Paris"),ClockZone(name:"纽约",zone:"America/New_York"),ClockZone(name:"洛杉矶",zone:"America/Los_Angeles"),ClockZone(name:"悉尼",zone:"Australia/Sydney")]
    static let suggested=[ClockZone(name:"香港",zone:"Asia/Hong_Kong"),ClockZone(name:"台北",zone:"Asia/Taipei"),ClockZone(name:"首尔",zone:"Asia/Seoul"),ClockZone(name:"曼谷",zone:"Asia/Bangkok"),ClockZone(name:"迪拜",zone:"Asia/Dubai"),ClockZone(name:"柏林",zone:"Europe/Berlin"),ClockZone(name:"莫斯科",zone:"Europe/Moscow"),ClockZone(name:"温哥华",zone:"America/Vancouver"),ClockZone(name:"旧金山",zone:"America/Los_Angeles"),ClockZone(name:"芝加哥",zone:"America/Chicago"),ClockZone(name:"多伦多",zone:"America/Toronto"),ClockZone(name:"奥克兰",zone:"Pacific/Auckland")]
    static func formatted(_ date:Date,zone:String,format:String="MM-dd HH:mm:ss")->String {let f=DateFormatter();f.locale=Locale(identifier:"zh_CN");f.dateFormat=format;f.timeZone=TimeZone(identifier:zone);return f.string(from:date)}
    static func date(month:Int,day:Int,hour:Int,minute:Int,zone:String,reference:Date=Date())->Date? {
        guard let timeZone=TimeZone(identifier:zone),(1...12).contains(month),(1...31).contains(day),(0...23).contains(hour),(0...59).contains(minute) else {return nil}
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=timeZone
        let year=calendar.component(.year,from:reference)
        guard let value=calendar.date(from:DateComponents(year:year,month:month,day:day,hour:hour,minute:minute)) else {return nil}
        let parts=calendar.dateComponents([.year,.month,.day,.hour,.minute],from:value)
        guard parts.year == year,parts.month == month,parts.day == day,parts.hour == hour,parts.minute == minute else {return nil};return value
    }
}
@MainActor final class WorldClockLibrary:ObservableObject {
    @Published private(set) var custom:[ClockZone]=[]
    @Published private(set) var hiddenDefaults:Set<String>=[]
    private let defaults:UserDefaults
    private let key="findduck.world-clock.custom-cities"
    private let hiddenKey="findduck.world-clock.hidden-default-cities"
    init(defaults:UserDefaults = .standard) {
        self.defaults=defaults
        hiddenDefaults=Set(defaults.stringArray(forKey:hiddenKey) ?? [])
        if let data=defaults.data(forKey:key),let saved=try? JSONDecoder().decode([ClockZone].self,from:data) {
            custom=saved.filter {TimeZone(identifier:$0.zone) != nil && !$0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
        }
    }
    var zones:[ClockZone] {WorldTimes.zones.filter {!hiddenDefaults.contains($0.id)}+custom}
    @discardableResult func add(name:String,zone:String)->Bool {
        let city=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !city.isEmpty,city.count<=40,TimeZone(identifier:zone) != nil,
              !zones.contains(where:{$0.name.localizedCaseInsensitiveCompare(city) == .orderedSame}) else {return false}
        custom.append(ClockZone(name:city,zone:zone));persist();return true
    }
    func remove(_ city:ClockZone) {
        guard zones.count > 1 else {return}
        if WorldTimes.zones.contains(city) {hiddenDefaults.insert(city.id)}
        else {custom.removeAll {$0.id == city.id}}
        persist()
    }
    private func persist() {
        if let data=try? JSONEncoder().encode(custom) {defaults.set(data,forKey:key)}
        defaults.set(hiddenDefaults.sorted(),forKey:hiddenKey)
    }
}
private struct WorldClockView:View {
    @StateObject private var library=WorldClockLibrary()
    @State private var source=WorldTimes.zones[0].id
    @State private var target=WorldTimes.zones[5].id
    @State private var adding=false
    @State private var month=""
    @State private var day=""
    @State private var hour=""
    @State private var minute=""
    private var sourceZone:String {library.zones.first(where:{$0.id == source})?.zone ?? WorldTimes.zones[0].zone}
    private var targetZone:String {library.zones.first(where:{$0.id == target})?.zone ?? WorldTimes.zones[5].zone}
    private var converted:Date? {guard let m=Int(month),let d=Int(day),let h=Int(hour),let n=Int(minute) else {return nil};return WorldTimes.date(month:m,day:d,hour:h,minute:n,zone:sourceZone)}
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {Text("城市时间").font(.system(size:13,weight:.semibold));Spacer();Button {adding=true} label: {Label("增加城市",systemImage:"plus")}}
            ScrollView {
                TimelineView(.periodic(from:.now,by:1)) {context in
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:4),spacing:10) {
                        ForEach(library.zones) {zone in
                            VStack(alignment:.leading,spacing:4) {
                                HStack(spacing:3) {Text(zone.name).lineLimit(1).font(.caption).foregroundStyle(.secondary);Spacer(minLength:0)
                                    if library.zones.count > 1 {Button {remove(zone)} label: {Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary)}.buttonStyle(.plain).help("移除城市")}}
                                Text(WorldTimes.formatted(context.date,zone:zone.zone,format:"HH:mm:ss")).font(.system(size:17,weight:.medium)).monospacedDigit()
                                Text(WorldTimes.formatted(context.date,zone:zone.zone,format:"MM月dd日")).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(9).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:9))
                                .contextMenu {if library.zones.count > 1 {Button("删除城市",role:.destructive) {remove(zone)}}}
                        }
                    }
                }
            }.frame(maxHeight:230)
            Divider();Text("时间换算").font(.system(size:13,weight:.semibold))
            HStack {Picker("从",selection:$source) {ForEach(library.zones) {Text($0.name).tag($0.id)}};Image(systemName:"arrow.right").foregroundStyle(.secondary);Picker("到",selection:$target) {ForEach(library.zones) {Text($0.name).tag($0.id)}}}
            HStack(spacing:7) {
                dateField("月份",text:$month);Text("月");dateField("日期",text:$day);Text("日");dateField("小时",text:$hour);Text(":");dateField("分钟",text:$minute);Spacer();Button("现在") {now()}
            }.font(.system(size:13)).monospacedDigit()
            VStack(alignment:.leading,spacing:5) {Text("换算结果").font(.caption).foregroundStyle(.secondary);Text(converted.map {WorldTimes.formatted($0,zone:targetZone,format:"MM月dd日 HH:mm")} ?? "请输入有效日期和时间").font(.system(size:21,weight:.medium)).monospacedDigit().textSelection(.enabled)}.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Color.accentColor.opacity(0.07),in:RoundedRectangle(cornerRadius:10))
            Text("日期按当前年份计算，自动处理所选时区的夏令时。").font(.caption).foregroundStyle(.secondary)
        }.onAppear {now()}.sheet(isPresented:$adding) {AddClockCityView(library:library)}
    }
    private func dateField(_ title:String,text:Binding<String>)->some View {TextField(title,text:text).textFieldStyle(.roundedBorder).frame(width:42).multilineTextAlignment(.center).accessibilityLabel(title)}
    private func now() {let value=Date();month=WorldTimes.formatted(value,zone:sourceZone,format:"MM");day=WorldTimes.formatted(value,zone:sourceZone,format:"dd");hour=WorldTimes.formatted(value,zone:sourceZone,format:"HH");minute=WorldTimes.formatted(value,zone:sourceZone,format:"mm")}
    private func remove(_ zone:ClockZone) {
        library.remove(zone)
        if source == zone.id {source=library.zones.first?.id ?? WorldTimes.zones[0].id}
        if target == zone.id {target=library.zones.last?.id ?? WorldTimes.zones[0].id}
    }
}
private struct AddClockCityView:View {
    @ObservedObject var library:WorldClockLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var name=""
    @State private var search=""
    @State private var selected=""
    @State private var error=""
    private var matches:[ClockZone] {
        let query=search.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !query.isEmpty else {return WorldTimes.suggested}
        let normalized=query.replacingOccurrences(of:" ",with:"_")
        let suggestions=WorldTimes.suggested.filter {$0.name.localizedCaseInsensitiveContains(query) || $0.zone.localizedCaseInsensitiveContains(normalized)}
        let known=TimeZone.knownTimeZoneIdentifiers.filter {identifier in identifier.localizedCaseInsensitiveContains(normalized) && !suggestions.contains(where:{$0.zone == identifier})}
        return suggestions+known.prefix(max(0,30-suggestions.count)).map {ClockZone(name:$0.split(separator:"/").last.map {String($0).replacingOccurrences(of:"_",with:" ")} ?? $0,zone:$0)}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("增加世界时间城市").font(.headline)
            TextField("搜索城市或时区，例如：温哥华、Vancouver",text:$search)
                .accessibilityLabel("搜索城市或时区")
            Text("先从列表选择城市，Biu会自动匹配时区。").font(.caption).foregroundStyle(.secondary)
            if !selected.isEmpty {
                TextField("显示名称（可改）",text:$name).accessibilityLabel("城市显示名称")
                Text("显示名称只影响卡片文字；实际时间按已选时区 "+selected+" 计算。").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {LazyVStack(spacing:2) {ForEach(matches) {city in
                Button {selected=city.zone;if name.isEmpty {name=city.name}} label: {
                    HStack {Text(city.name);Text(city.zone).font(.caption).foregroundStyle(.secondary);Spacer();Text(WorldTimes.formatted(Date(),zone:city.zone,format:"HH:mm")).foregroundStyle(.secondary)}.padding(.horizontal,8).padding(.vertical,5).background(selected == city.zone ? FindDuckHighlight.soft : Color.clear,in:RoundedRectangle(cornerRadius:6))
                }.buttonStyle(.plain).accessibilityLabel(city.name+"，"+city.zone)
            }}}.frame(height:210)
            if !error.isEmpty {Text(error).font(.caption).foregroundStyle(.red)}
            HStack {Spacer();Button("取消") {dismiss()};Button("添加") {if library.add(name:name,zone:selected) {dismiss()} else {error="请输入城市名称并选择时区；城市名称不能重复。"}}.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || selected.isEmpty)}
        }.padding(20).frame(width:440)
    }
}
