import AppKit
import SwiftUI
import Research

struct GeneralSettings:View {
    @AppStorage("gqns.language") private var language="system"
    @AppStorage("gqns.appearance") private var appearance="system"
    var body:some View {
        Form {
            Picker("语言",selection:$language) { Text("跟随系统").tag("system");Text("中文").tag("zh-Hans");Text("English").tag("en") }
            Picker("外观",selection:$appearance) { Text("跟随系统").tag("system");Text("浅色").tag("light");Text("深色").tag("dark") }
            LabeledContent("版本",value:"V"+(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "?"))
        }.formStyle(.grouped).onChange(of:appearance) { _,_ in AppAppearance.current.apply() }
    }
}
enum AppAppearance:String {
    case system,light,dark
    static var current:Self { Self(rawValue:UserDefaults.standard.string(forKey:"gqns.appearance") ?? "system") ?? .system }
    func apply() { guard let app=NSApp else { DispatchQueue.main.async {self.apply()};return };app.appearance=self == .system ? nil : NSAppearance(named:self == .dark ? .darkAqua : .aqua) }
}
enum AppDataLocations {
    static var appSupport:URL? { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first?.appendingPathComponent("GaoSeries/Research",isDirectory:true) }
    static var groupContainer:URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:"5G96498KGJ.com.academic-achievement.manager") }
}
struct DataSettings:View {
    @State private var status=""
    var body:some View {
        Form {
            Section("本地资料") {
                Text("业务历史、游戏进度、PDF、Word、图片及全部附件仅保存在本应用的专用数据目录；密钥继续由系统钥匙串保管。应用不创建自动、手动或升级备份。")
            }
            Section("数据目录") {
                Button("打开数据目录") { reveal(AppDataLocations.appSupport) }
                Button("打开小组件共享目录") { reveal(AppDataLocations.groupContainer) }
            }
            if !status.isEmpty { Text(status).textSelection(.enabled) }
        }.formStyle(.grouped)
    }
    private func reveal(_ url:URL?) {
        if let url {
            do {
                try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                NSWorkspace.shared.open(url)
            } catch { status=error.localizedDescription }
        }
    }
}
