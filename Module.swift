import SwiftUI
import Foundation

public final class ResearchBundleMarker: NSObject {}
enum ResearchBundle {
    static let bundle = Bundle(for: ResearchBundleMarker.self)
    static let defaults = UserDefaults(suiteName: ProcessInfo.processInfo.environment["GAOQINIANSAN_INTEGRATION_TEST"] == "1" ? "com.academic-achievement.manager.test.Research" : "com.academic-achievement.manager.Research") ?? .standard
}

@MainActor private enum ResearchRuntime {
    static let store = PaperStore()
    static let settings = AppSettings()
    static let menuState = MenuCommandState()
    static var exportedInitialSnapshot = false
    static func exportInitialSnapshotIfNeeded() {
        guard !exportedInitialSnapshot else { return }
        exportedInitialSnapshot = true
        store.exportWidgetSnapshot()
    }
}

public struct ResearchModuleView: View {
    @ObservedObject private var store = ResearchRuntime.store
    @ObservedObject private var settings = ResearchRuntime.settings
    @ObservedObject private var menuState = ResearchRuntime.menuState
    private let route: URL?
    private let routeRevision: Int
    @State private var handledRevision = 0
    public init(route: URL? = nil, routeRevision: Int = 0) {
        self.route = route
        self.routeRevision = routeRevision
    }
    public var body: some View {
        ContentView()
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(menuState)
            .environment(\.locale, settings.language.locale)
            .onAppear { ResearchRuntime.exportInitialSnapshotIfNeeded() }
            .onAppear(perform: handleRoute)
            .onChange(of: routeRevision) { _, _ in handleRoute() }
            // 备份导出/恢复收拢到 app 级「数据」页：模块内入口已移除，能力经通知触发。
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.research.export"))) { _ in
                store.exportFullBackup()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.research.import"))) { _ in
                store.chooseAndRestoreFullBackup()
            }
    }
    private func handleRoute() {
        guard routeRevision > handledRevision, let route else { return }
        handledRevision = routeRevision
        if route.scheme == "gaoyanjiu" {
            let target = route.host ?? ""
            if target == "submissions" || target == "works" {
                NotificationCenter.default.post(name: .appOpenWidgetDeepLink, object: target)
            }
        } else if route.isFileURL && route.pathExtension.lowercased() == "gaoaction" {
            store.handleIncomingPackage(at: route)
        }
    }
}

/// 搞研究设置页（app 级设置中心嵌入用）：内容与模块原设置 sheet 完全一致，
/// store/settings 由 framework 内 singleton 注入，外部嵌入无需提供环境对象。
public struct ResearchSettingsView: View {
    @ObservedObject private var store = ResearchRuntime.store
    @ObservedObject private var settings = ResearchRuntime.settings
    public init() {}
    public var body: some View {
        AppSettingsView()
            .environmentObject(store)
            .environmentObject(settings)
            .environment(\.locale, settings.language.locale)
    }
}

