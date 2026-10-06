import Accessibility
import SwiftUI

enum AppearancePreference: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: AppLocalization.text("浅色")
        case .dark: AppLocalization.text("深色")
        case .system: AppLocalization.text("跟随系统")
        }
    }

    var symbol: String {
        switch self {
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        case .system: "circle.lefthalf.filled"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }
}

enum AppLanguagePreference: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let appearance = "appearancePreference"
        static let language = "languagePreference"
        static let notificationsEnabled = "notificationsEnabled"
        static let submissionReminderDays = "submissionReminderDays"
        static let projectReminderLeadDays = "projectReminderLeadDays"
    }

    private let defaults: UserDefaults

    @Published var appearance: AppearancePreference {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    /// 界面语言：统一读 app 级设置中心的 gqns.language（system/zh-Hans/en），模块内不再单独持久化。
    /// system 解析规则见 GQNSLanguage。
    var language: AppLanguagePreference {
        AppLanguagePreference(rawValue: GQNSLanguage.localeIdentifier) ?? .simplifiedChinese
    }

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    @Published var submissionReminderDays: Int {
        didSet { defaults.set(submissionReminderDays, forKey: Keys.submissionReminderDays) }
    }

    @Published var projectReminderLeadDays: Int {
        didSet { defaults.set(projectReminderLeadDays, forKey: Keys.projectReminderLeadDays) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 旧版模块级语言偏好（languagePreference）一次性迁移到 app 级 gqns.language。
        GQNSLanguage.migrateLegacy(defaults: .standard, legacyKey: Keys.language)
        appearance = defaults.string(forKey: Keys.appearance)
            .flatMap(AppearancePreference.init(rawValue:)) ?? .light
        notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        let storedSubmissionDays = defaults.integer(forKey: Keys.submissionReminderDays)
        submissionReminderDays = storedSubmissionDays > 0 ? storedSubmissionDays : 60
        let storedProjectDays = defaults.integer(forKey: Keys.projectReminderLeadDays)
        projectReminderLeadDays = storedProjectDays > 0 ? storedProjectDays : 3
        // gqns.language 由 app 级设置中心修改；.defaults 变化时通知界面按新语言重渲染。
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }
}

enum AppLocalization {
    // 语言来源统一为 app 级 gqns.language（GQNSLanguage 每次直读 UserDefaults.standard，
    // 天然线程安全，替代原先无保护的全局可变 static var）；全部现有只读调用点保持不变。
    static var language: AppLanguagePreference {
        AppLanguagePreference(rawValue: GQNSLanguage.localeIdentifier) ?? .simplifiedChinese
    }

    static func text(_ key: String) -> String {
        let current = language
        guard
            let path = ResearchBundle.bundle.path(forResource: current.rawValue, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: language.locale, arguments: arguments)
    }
}

// MARK: - V4.6 batch-S：Swift Charts 读屏描述
// SDK 的 .accessibilityChartDescriptor 接收 AXChartDescriptorRepresentable（macOS 12+）；
// AXChartDescriptor 本体是 objc_subclassing_restricted 的类，只能构造不能子类化，
// 因此用轻量 struct 包装后交给修饰符。
struct LocalizedChartDescriptor: AXChartDescriptorRepresentable {
    let descriptor: AXChartDescriptor

    func makeChartDescriptor() -> AXChartDescriptor { descriptor }
}

enum ChartAccessibility {
    /// 类别 × 数值的单系列统计图（横向/纵向柱状、折线均适用）。
    /// 视觉上是横向条形图时，音频图仍以「类别 → 数值」朗读，因此类别恒置于 xAxis。
    /// 全部文案经 AppLocalization，与图表可见标题共用同一批键。
    static func descriptor(
        title: String,
        summary: String,
        categoryAxisTitle: String,
        valueAxisTitle: String,
        points: [(category: String, value: Double)],
        valueDescription: @escaping (Double) -> String
    ) -> LocalizedChartDescriptor {
        let maximum = max(points.map(\.value).max() ?? 0, 1)
        let series = AXDataSeriesDescriptor(
            name: title,
            isContinuous: false,
            dataPoints: points.map { AXDataPoint(x: $0.category, y: $0.value) }
        )
        let descriptor = AXChartDescriptor(
            title: title,
            summary: summary,
            xAxis: AXCategoricalDataAxisDescriptor(
                title: categoryAxisTitle,
                categoryOrder: points.map(\.category)
            ),
            yAxis: AXNumericDataAxisDescriptor(
                title: valueAxisTitle,
                range: 0...maximum,
                gridlinePositions: [],
                valueDescriptionProvider: valueDescription
            ),
            series: [series]
        )
        return LocalizedChartDescriptor(descriptor: descriptor)
    }
}

struct AppSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: PaperStore
    @Environment(\.dismiss) private var dismiss
    @State private var notificationStatus = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppLocalization.text("设置"))
                        .font(.title2.weight(.semibold))
                    Text(AppLocalization.text("界面偏好仅保存在这台 Mac，不会修改论文、成果或附件。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(AppLocalization.text("完成")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)

            Divider()

            Form {
                Section {
                    Toggle(AppLocalization.text("启用系统提醒"), isOn: $settings.notificationsEnabled)
                    Stepper(
                        AppLocalization.format("投稿状态持续 %d 天提醒", settings.submissionReminderDays),
                        value: $settings.submissionReminderDays,
                        in: 15...180,
                        step: 5
                    )
                    Stepper(
                        AppLocalization.format("项目截止前 %d 天提醒", settings.projectReminderLeadDays),
                        value: $settings.projectReminderLeadDays,
                        in: 1...30
                    )
                    Button(AppLocalization.text("立即更新提醒")) {
                        Task {
                            notificationStatus = await NotificationManager.shared.configure(
                                store: store,
                                settings: settings,
                                requestAuthorization: true
                            )
                        }
                    }
                    .disabled(!settings.notificationsEnabled)
                    if !notificationStatus.isEmpty {
                        Text(notificationStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(AppLocalization.text("系统通知"))
                } footer: {
                    Text(AppLocalization.text("提醒只在本机生成，包含投稿状态超期和项目步骤截止日期。"))
                }

                Section {
                    Button(AppLocalization.text("重新建立文件全文索引")) { store.rebuildDocumentSearchIndex() }
                        .disabled(store.isIndexingDocuments)
                    if store.isIndexingDocuments { ProgressView() }
                    if !store.indexingMessage.isEmpty {
                        Text(store.indexingMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(AppLocalization.text("文件搜索"))
                } footer: {
                    Text(AppLocalization.text("可搜索 PDF、文本以及系统能够提取正文的 Word、Excel 和 PPT 文件。"))
                }

                Section {
                    Text(AppLocalization.text("模块已并入搞研究，随整合版更新。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(AppLocalization.text("软件更新"))
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
        }
        // 3.38：设置页从写死 660pt 宽改为自适应——嵌入 app 级设置中心（580pt 页签）时收缩不裁切，
        // 理想/上限仍是 660（原模块 sheet 场景已不存在，嵌入是唯一用途）。
        .frame(minWidth: 460, idealWidth: 660, maxWidth: 660)
        .frame(minHeight: 0, idealHeight: 690, maxHeight: .infinity)
    }
}
