import AppKit
import SwiftUI

// A small arithmetic grammar; no script evaluation or external process is involved.
enum DuckCalculator {
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
        self.file=file ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("com.chenhuang.smbsearch/quick-texts.json")
        if let data=try? Data(contentsOf:self.file),let values=try? JSONDecoder().decode([QuickText].self,from:data) {items=values}
    }
    func save(_ item:QuickText) {if let i=items.firstIndex(where:{$0.id == item.id}) {items[i]=item} else {items.append(item)};persist()}
    func remove(_ item:QuickText) {items.removeAll {$0.id == item.id};persist()}
    private func persist() {do {try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONEncoder().encode(items).write(to:file,options:.atomic)} catch {self.error=error.localizedDescription}}
}
enum HomeTool:String,Identifiable {case snippets="快捷文本",rates="人民币汇率",world="世界时间";var id:String {rawValue}}
struct QuickToolsPanel:View {
    let tool:HomeTool
    @Environment(\.dismiss) private var dismiss
    var body:some View {VStack(alignment:.leading,spacing:16) {HStack {Text(tool.rawValue).font(.headline);Spacer();Button("完成") {dismiss()}};switch tool {case .snippets:QuickTextsView();case .rates:ExchangeRatesView();case .world:WorldClockView()}}.padding(20).frame(width:560,height:440)}
}
private struct QuickTextsView:View {
    @StateObject private var model=QuickTextLibrary()
    @State private var editing:QuickText?
    @State private var copied=""
    var body:some View {
        VStack(alignment:.leading) {
            List {ForEach(model.items) {item in HStack {
                Button {NSPasteboard.general.clearContents();NSPasteboard.general.setString(item.text,forType:.string);copied="已复制："+item.title} label: {VStack(alignment:.leading) {Text(item.title);Text(item.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)}}.buttonStyle(.plain).frame(maxWidth:.infinity,alignment:.leading)
                Button("编辑") {editing=item};Button("删除") {model.remove(item)}
            }.padding(.vertical,5)}}
            HStack {Button("增加文本") {editing=QuickText(title:"",text:"")};Text(model.error.isEmpty ? copied : model.error).font(.caption).foregroundStyle(.secondary)}
        }.sheet(item:$editing) {item in QuickTextEditor(item:item,save:model.save)}
    }
}
private struct QuickTextEditor:View {
    @State var item:QuickText
    let save:(QuickText)->Void
    @Environment(\.dismiss) private var dismiss
    var body:some View {VStack(alignment:.leading,spacing:12) {TextField("名称",text:$item.title);TextEditor(text:$item.text).frame(height:180);HStack {Button("取消") {dismiss()};Spacer();Button("保存") {save(item);dismiss()}.disabled(item.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || item.text.isEmpty)}}.padding(20).frame(width:400)}
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
private struct ExchangeRatesView:View {
    @State private var rates:[ExchangeRate]=[]
    @State private var error=""
    @State private var loading=false
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {Text("1 单位外币 = 人民币").foregroundStyle(.secondary);Spacer();Button("刷新") {Task {await refresh()}}.disabled(loading)}
            if loading {ProgressView()}
            if !error.isEmpty {Text(error).foregroundStyle(.secondary)}
            ForEach(rates) {rate in HStack {Text(rate.quote).fontWeight(.medium);Spacer();Text((1/rate.rate).formatted(.number.precision(.fractionLength(4)))+" 元").monospacedDigit();Text(rate.date).font(.caption).foregroundStyle(.secondary)}}
            Spacer();Link("来源：Frankfurter",destination:URL(string:"https://frankfurter.dev/")!).font(.caption)
            Text("每日参考汇率，日期见各行；非银行实时成交价。").font(.caption).foregroundStyle(.secondary)
        }.task {await refresh()}
    }
    private func refresh() async {loading=true;defer {loading=false};do {rates=try await ExchangeRates.load();error=""} catch {self.error=rates.isEmpty ? "汇率暂时无法获取，请检查网络后重试。" : "刷新失败，仍显示上次数据。"}}
}
struct ClockZone:Identifiable {let name:String;let zone:String;var id:String {zone}}
enum WorldTimes {
    static let zones=[ClockZone(name:"北京",zone:"Asia/Shanghai"),ClockZone(name:"东京",zone:"Asia/Tokyo"),ClockZone(name:"新加坡",zone:"Asia/Singapore"),ClockZone(name:"伦敦",zone:"Europe/London"),ClockZone(name:"巴黎",zone:"Europe/Paris"),ClockZone(name:"纽约",zone:"America/New_York"),ClockZone(name:"洛杉矶",zone:"America/Los_Angeles"),ClockZone(name:"悉尼",zone:"Australia/Sydney")]
    static func formatted(_ date:Date,zone:String)->String {let f=DateFormatter();f.locale=Locale(identifier:"zh_CN");f.dateFormat="MM-dd HH:mm:ss";f.timeZone=TimeZone(identifier:zone);return f.string(from:date)}
}
private struct WorldClockView:View {
    @State private var source="Asia/Shanghai"
    @State private var target="America/New_York"
    @State private var date=Date()
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            TimelineView(.periodic(from:.now,by:1)) {context in
                LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],alignment:.leading,spacing:10) {
                    ForEach(WorldTimes.zones) {zone in HStack {Text(zone.name);Spacer();Text(WorldTimes.formatted(context.date,zone:zone.zone)).monospacedDigit().foregroundStyle(.secondary)}}
                }
            }
            Divider();Text("时间换算").fontWeight(.medium)
            HStack {Picker("从",selection:$source) {ForEach(WorldTimes.zones) {Text($0.name).tag($0.zone)}};Picker("到",selection:$target) {ForEach(WorldTimes.zones) {Text($0.name).tag($0.zone)}}}
            DatePicker("当地时间",selection:$date,displayedComponents:[.date,.hourAndMinute]).environment(\.timeZone,TimeZone(identifier:source)!)
            Text("换算结果："+WorldTimes.formatted(date,zone:target)).font(.title3).monospacedDigit()
            Text("按所选日期自动处理夏令时。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
