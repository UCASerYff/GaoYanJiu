import SwiftUI
import Foundation
import AppKit

public final class ResearchBundleMarker: NSObject {}
enum ResearchBundle {
    static let bundle = Bundle(for: ResearchBundleMarker.self)
    static let defaults = UserDefaults(suiteName: ProcessInfo.processInfo.environment["GAOQINIANSAN_INTEGRATION_TEST"] == "1" ? "com.academic-achievement.manager.test.Research" : "com.academic-achievement.manager.Research") ?? .standard
}

@MainActor private enum ResearchRuntime {
    static let store = PaperStore()
    static let settings = AppSettings()
    static let menuState = MenuCommandState()
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
            .onAppear(perform: handleRoute)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                store.exportWidgetSnapshot(reason: .activation)
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                store.exportWidgetSnapshot(reason: .wake)
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                store.exportWidgetSnapshot(reason: .calendarChanged)
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                store.exportWidgetSnapshot(reason: .calendarChanged)
            }
            .onChange(of: settings.language) { _, _ in
                store.exportWidgetSnapshot(reason: .languageChanged)
            }
            .onChange(of: routeRevision) { _, _ in handleRoute() }
            .sheet(item: $store.pendingPackageReview) { context in
                ActionPackageReviewSheet(context: context)
                    .environmentObject(store)
            }
            .sheet(item: Binding(get: { store.documentLibrary.pendingExchangeResultReview },
                                 set: { store.documentLibrary.pendingExchangeResultReview = $0 })) { review in
                ExchangeResultReviewSheet(review: review)
                    .environmentObject(store)
            }
            .alert(isPresented: Binding(get: { store.exchangeFeedbackMessage != nil },
                                        set: { if !$0 { store.exchangeFeedbackMessage = nil } })) {
                Alert(title: Text(AppLocalization.text("资料交接反馈")),
                      message: Text(store.exchangeFeedbackMessage ?? ""),
                      dismissButton: .default(Text(AppLocalization.text("知道了"))) {
                    store.exchangeFeedbackMessage = nil
                })
            }
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

