import AppKit
import Foundation

@MainActor
enum ResearchFundingHandoffClient {
    static func open(recordID: String? = nil, completion: @escaping (String?) -> Void) {
        let application = URL(fileURLWithPath: "/Applications/搞积蓄.app", isDirectory: true)
        guard let bundle = Bundle(url: application), bundle.bundleIdentifier == ResearchFundingHandoff.targetBundleID,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              ResearchFundingHandoff.supportsTargetVersion(version) else {
            completion(AppLocalization.text("请先安装支持科研资金的搞积蓄4.04或更新版本。原资金资料仍完整保留。"))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([ResearchFundingHandoff.destination(recordID: recordID)],
                                withApplicationAt: application, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                completion(error.map { AppLocalization.format("未能打开搞积蓄：%@", $0.localizedDescription) })
            }
        }
    }
}
