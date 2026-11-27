import SwiftUI
import AppKit
import UserNotifications
import Research

/// Maintenance commands run before SwiftUI creates the app or its data store.
/// They read the existing library and never create a replacement library.
@main enum StandaloneEntry {
    @MainActor static func main() {
        ResearchStartupDiagnostics.mark("host-entry")
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--startup-diagnostics" {
            guard arguments.count == 2, let pid = Int32(arguments[1]), pid > 0 else {
                FileHandle.standardError.write(Data("Usage: --startup-diagnostics <GUI-process-PID>\n".utf8))
                exit(2)
            }
            do {
                FileHandle.standardOutput.write(try ResearchStartupDiagnostics.readPrivateFile(processID: pid))
                FileHandle.standardOutput.write(Data("\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("Startup timing unavailable or unsafe; no measurement returned.\n".utf8))
                exit(1)
            }
            return
        }
        if arguments == ["--widget-diagnostics"] {
            FileHandle.standardOutput.write(ResearchWidgetMaintenance.diagnostics())
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }
        if arguments == ["--refresh-widget-snapshot"] {
            do {
                FileHandle.standardOutput.write(try ResearchWidgetMaintenance.refreshFromDisk())
                FileHandle.standardOutput.write(Data("\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("Widget publication failed; the existing library and last valid snapshot are preserved.\n".utf8))
                exit(1)
            }
            return
        }
        ResearchStartupDiagnostics.enablePrivateFileOutput(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        StandaloneApp.main()
    }
}

struct StandaloneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var route: URL?
    @State private var revision = 0
    @State private var dataError: String?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    init() {
        AppAppearance.current.apply()
    }
    static func activate() {
        NSApp.activate(ignoringOtherApps:true)
        if let w=NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) ?? NSApp.windows.first(where:{$0.styleMask.contains(.titled) && !($0 is NSPanel)}) {
            if w.isMiniaturized { w.deminiaturize(nil) };w.makeKeyAndOrderFront(nil)
        }
    }
    private static let menuBarIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AcademicAchievementManagerIcon", withExtension: "png"),
              let icon = NSImage(contentsOf: url) else { return nil }
        icon.size = NSSize(width: 18, height: 18)
        return icon
    }()
    private func showMainWindow() {
        openWindow(id: "main")
        Self.activate()
    }
    private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = "退出搞研究？"
        alert.informativeText = "如有尚未保存的编辑，请选择取消并返回工作台。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "退出")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { NSApp.terminate(nil) }
    }
    var body: some Scene {
        Window("搞研究 V\(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "?")",id:"main") {
            ResearchModuleView(route:route,routeRevision:revision)
                .onAppear {
                    ResearchStartupDiagnostics.mark("content-first-appeared")
                    let open = openWindow
                    delegate.showMainWindow = { open(id: "main"); Self.activate() }
                }
                .frame(minWidth:1040,minHeight:720)
                .modifier(WindowToolbarOpaqueBackground())
                .task {  }
                .onReceive(NotificationCenter.default.publisher(for:Notification.Name("GaoSeries.dataError"))) { dataError=$0.userInfo?["message"] as? String }
                .alert("数据操作未完成",isPresented:Binding(get:{dataError != nil},set:{if !$0 {dataError=nil}})) { Button("知道了") {dataError=nil} } message:{Text(dataError ?? "")}
                .onReceive(NotificationCenter.default.publisher(for:Notification.Name("GaoSeries.app.openSettings"))) { _ in openSettings() }
                .onReceive(NotificationCenter.default.publisher(for:Notification.Name("appOpenSettings"))) { _ in openSettings() }
                .onReceive(NotificationCenter.default.publisher(for:Notification.Name("Standalone.showWindow"))) { _ in showMainWindow() }
                
                .onOpenURL { url in
                    route=url;revision &+= 1;showMainWindow()
                    
                }
        }
        .defaultSize(width:1380,height:860)
        .handlesExternalEvents(matching:["*"])
        .commands {
            CommandGroup(after:.newItem) { Button("新增成果") {post("appCreateRecord")}.keyboardShortcut("n");Button("搜索") {post("appFocusSearch")}.keyboardShortcut("f");Button("刷新投稿") {post("appRefreshSubmissions")} }
        }
        MenuBarExtra {
            Button("打开搞研究", action: showMainWindow)
            Divider()
            Button("退出搞研究", action: confirmQuit)
        } label: {
            if let icon = Self.menuBarIcon {
                Image(nsImage: icon).accessibilityLabel("搞研究")
            } else {
                Label("搞研究", systemImage: "doc.text.magnifyingglass")
            }
        }
        Settings {
            TabView {
                ResearchSettingsView().tabItem { Label("模块设置",systemImage:"slider.horizontal.3") }
                GeneralSettings().tabItem { Label("外观",systemImage:"paintpalette") }
                DataSettings().tabItem { Label("数据",systemImage:"externaldrive") }
            }.frame(width:820,height:740)
        }
        
    }
}
func post(_ name:String) { NotificationCenter.default.post(name:Notification.Name(name),object:nil) }
final class AppDelegate:NSObject,NSApplicationDelegate,UNUserNotificationCenterDelegate {
    var showMainWindow: (() -> Void)?
    func applicationDidFinishLaunching(_ notification:Notification) { UNUserNotificationCenter.current().delegate=self }
    func applicationWillTerminate(_ notification:Notification) { ResearchStartupDiagnostics.flushPrivateFileOutput() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let showMainWindow else { return true }
        showMainWindow()
        return false
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        
        return .terminateNow
    }
    func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler completionHandler:@escaping(UNNotificationPresentationOptions)->Void) { completionHandler([.banner,.list,.sound]) }
    func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse,withCompletionHandler completionHandler:@escaping()->Void) {
        DispatchQueue.main.async { [weak self] in
            if let showMainWindow = self?.showMainWindow { showMainWindow() }
            else { post("Standalone.showWindow") }
            completionHandler()
        }
    }
}
private struct WindowToolbarOpaqueBackground:ViewModifier {
    func body(content:Content)->some View {
        if #available(macOS 15.0,*) { content.toolbarBackground(AppTheme.canvas,for:.windowToolbar).toolbarBackgroundVisibility(.visible,for:.windowToolbar) }
        else { content.toolbarBackground(AppTheme.canvas,for:.windowToolbar) }
    }
}
