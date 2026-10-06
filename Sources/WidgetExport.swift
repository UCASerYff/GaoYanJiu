import Foundation
import WidgetKit

extension PaperStore {
    private func reloadWidgetsForCurrentRelease(force: Bool = false) {
        let release = ResearchBundle.bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let key = "lastWidgetLayoutRelease"
        guard force || ResearchBundle.defaults.string(forKey: key) != release else { return }
        WidgetCenter.shared.reloadAllTimelines()
        ResearchBundle.defaults.set(release, forKey: key)
    }

    func exportWidgetSnapshot() {
        guard ProcessInfo.processInfo.environment["GAO_RESEARCH_DATA_DIR"] == nil else { return }
        guard !libraryLoadFailed else { return }
        guard let url = ResearchWidgetSnapshot.fileURL else { return }
        let english = AppLocalization.language == .english
        // 终态判断统一走 SubmissionStatusClassifier（跨 agent 约定接口），本地不再维护关键词数组。
        let categories = ExistingWorkType.allCases.flatMap { type -> [ResearchWidgetSnapshot.Count] in
            if type == .patent {
                var result = PatentType.allCases.map { subtype in
                    ResearchWidgetSnapshot.Count(id: "patent-\(subtype.rawValue)", label: subtype.title,
                        count: existingWorks.filter { $0.type == .patent && $0.patentType == subtype }.count)
                }
                result.append(.init(id: "patent-unspecified", label: english ? "Other patents" : "未细分专利",
                                    count: existingWorks.filter { $0.type == .patent && $0.patentType == nil }.count))
                return result.filter { $0.count > 0 }
            }
            let count = existingWorks.filter { $0.type == type }.count
            return count == 0 ? [] : [.init(id:type.rawValue,label:type.title,count:count)]
        }
        var authors = AuthorPosition.allCases.map { position in
            ResearchWidgetSnapshot.Count(id:position.rawValue,label:position.title,count:existingWorks.filter { $0.authorPosition == position }.count)
        }
        let unassigned = existingWorks.filter { $0.authorPosition == nil }.count
        if unassigned > 0 { authors.append(.init(id:"unassigned",label:english ? "Unassigned" : "未填写",count:unassigned)) }
        let snapshot = ResearchWidgetSnapshot(updatedAt:Date(),english:english,
            papers:visiblePapers.map { p in
                .init(id:p.id,title:p.title,number:p.manuscriptID,since:p.statusSince,terminal:SubmissionStatusClassifier.isTerminal(p.status))
            },categories:categories,authors:authors,totalWorks:existingWorks.count)
        do {
            if let oldData = try? Data(contentsOf:url),
               let old = try? JSONDecoder().decode(ResearchWidgetSnapshot.self,from:oldData),
               old.english == snapshot.english, old.papers == snapshot.papers,
               old.categories == snapshot.categories, old.authors == snapshot.authors,
               old.totalWorks == snapshot.totalWorks {
                reloadWidgetsForCurrentRelease()
                return
            }
            let data = try JSONEncoder().encode(snapshot)
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try data.write(to:url,options:.atomic)
            reloadWidgetsForCurrentRelease(force: true)
        } catch { NSLog("Widget statistics export failed: %@",error.localizedDescription) }
    }
}
