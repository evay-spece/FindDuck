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
    var body:some View {VStack(alignment:.leading,spacing:16) {HStack {Text(tool.rawValue).font(.headline);Spacer();Button("完成") {dismiss()}};switch tool {case .snippets:QuickTextsView();case .rates:ExchangeRatesView();case .world:WorldClockView()}}.padding(20).frame(width:560,height:tool == .snippets ? 440 : tool == .rates ? 560 : 500)}
}
private struct QuickTextsView:View {
    @StateObject private var model=QuickTextLibrary()
    @State private var editing:QuickText?
    @State private var copied=""
    @State private var hovered:UUID?
    var body:some View {
        VStack(alignment:.leading) {
            List {ForEach(model.items) {item in HStack {
                VStack(alignment:.leading,spacing:4) {Text(item.title);Text(item.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)}
                    .frame(maxWidth:.infinity,alignment:.leading).padding(10).background(Color.accentColor.opacity(hovered == item.id ? 0.10 : 0),in:RoundedRectangle(cornerRadius:8)).contentShape(Rectangle())
                    .onHover {inside in if inside {hovered=item.id} else if hovered == item.id {hovered=nil}}
                    .onTapGesture(count:2) {copy(item)}.help("双击复制到剪切板").accessibilityAddTraits(.isButton).accessibilityAction {copy(item)}
                Button("编辑") {editing=item};Button("删除") {model.remove(item)}
            }.padding(.vertical,5)}}
            HStack {Text("双击文本复制").font(.caption).foregroundStyle(.secondary);Button("增加文本") {editing=QuickText(title:"",text:"")};Text(model.error.isEmpty ? copied : model.error).font(.caption).foregroundStyle(.secondary)}
        }.sheet(item:$editing) {item in QuickTextEditor(item:item,save:model.save)}
    }
    private func copy(_ item:QuickText) {NSPasteboard.general.clearContents();NSPasteboard.general.setString(item.text,forType:.string);copied="已复制："+item.title}
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
struct ClockZone:Identifiable {let name:String;let zone:String;var id:String {zone}}
enum WorldTimes {
    static let zones=[ClockZone(name:"北京",zone:"Asia/Shanghai"),ClockZone(name:"东京",zone:"Asia/Tokyo"),ClockZone(name:"新加坡",zone:"Asia/Singapore"),ClockZone(name:"伦敦",zone:"Europe/London"),ClockZone(name:"巴黎",zone:"Europe/Paris"),ClockZone(name:"纽约",zone:"America/New_York"),ClockZone(name:"洛杉矶",zone:"America/Los_Angeles"),ClockZone(name:"悉尼",zone:"Australia/Sydney")]
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
private struct WorldClockView:View {
    @State private var source="Asia/Shanghai"
    @State private var target="America/New_York"
    @State private var month=""
    @State private var day=""
    @State private var hour=""
    @State private var minute=""
    private var converted:Date? {guard let m=Int(month),let d=Int(day),let h=Int(hour),let n=Int(minute) else {return nil};return WorldTimes.date(month:m,day:d,hour:h,minute:n,zone:source)}
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            TimelineView(.periodic(from:.now,by:1)) {context in
                LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:4),spacing:12) {
                    ForEach(WorldTimes.zones) {zone in
                        VStack(alignment:.leading,spacing:4) {Text(zone.name).font(.caption).foregroundStyle(.secondary);Text(WorldTimes.formatted(context.date,zone:zone.zone,format:"HH:mm:ss")).font(.system(size:17,weight:.medium)).monospacedDigit();Text(WorldTimes.formatted(context.date,zone:zone.zone,format:"MM月dd日")).font(.caption).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,alignment:.leading).padding(9).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:9))
                    }
                }
            }
            Divider();Text("时间换算").font(.system(size:13,weight:.semibold))
            HStack {Picker("从",selection:$source) {ForEach(WorldTimes.zones) {Text($0.name).tag($0.zone)}};Image(systemName:"arrow.right").foregroundStyle(.secondary);Picker("到",selection:$target) {ForEach(WorldTimes.zones) {Text($0.name).tag($0.zone)}}}
            HStack(spacing:7) {
                dateField("月份",text:$month);Text("月");dateField("日期",text:$day);Text("日");dateField("小时",text:$hour);Text(":");dateField("分钟",text:$minute);Spacer();Button("现在") {now()}
            }.font(.system(size:13)).monospacedDigit()
            VStack(alignment:.leading,spacing:5) {Text("换算结果").font(.caption).foregroundStyle(.secondary);Text(converted.map {WorldTimes.formatted($0,zone:target,format:"MM月dd日 HH:mm")} ?? "请输入有效日期和时间").font(.system(size:21,weight:.medium)).monospacedDigit().textSelection(.enabled)}.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Color.accentColor.opacity(0.07),in:RoundedRectangle(cornerRadius:10))
            Text("日期按当前年份计算，自动处理所选时区的夏令时。").font(.caption).foregroundStyle(.secondary)
        }.onAppear {now()}
    }
    private func dateField(_ title:String,text:Binding<String>)->some View {TextField(title,text:text).textFieldStyle(.roundedBorder).frame(width:42).multilineTextAlignment(.center).accessibilityLabel(title)}
    private func now() {let value=Date();month=WorldTimes.formatted(value,zone:source,format:"MM");day=WorldTimes.formatted(value,zone:source,format:"dd");hour=WorldTimes.formatted(value,zone:source,format:"HH");minute=WorldTimes.formatted(value,zone:source,format:"mm")}
}
