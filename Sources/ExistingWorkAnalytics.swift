import CoreGraphics
import Foundation

struct ExistingWorkCategoryDatum: Identifiable, Equatable {
    let id: String
    let label: String
    let count: Int
}

enum ExistingWorkAnalytics {
    static func categories(for works: [ExistingWork]) -> [ExistingWorkCategoryDatum] {
        ExistingWorkType.allCases.flatMap { type -> [ExistingWorkCategoryDatum] in
            if type == .patent {
                var patentItems = PatentType.allCases.compactMap { patentType -> ExistingWorkCategoryDatum? in
                    let count = works.filter { $0.type == .patent && $0.patentType == patentType }.count
                    return count == 0 ? nil : ExistingWorkCategoryDatum(
                        id: "patent-\(patentType.rawValue)", label: patentType.title, count: count
                    )
                }
                let unspecified = works.filter { $0.type == .patent && $0.patentType == nil }.count
                if unspecified > 0 {
                    patentItems.append(ExistingWorkCategoryDatum(
                        id: "patent-unspecified", label: AppLocalization.text("未细分专利"), count: unspecified
                    ))
                }
                return patentItems
            }
            let count = works.filter { $0.type == type }.count
            return count == 0 ? [] : [ExistingWorkCategoryDatum(id: type.rawValue, label: type.title, count: count)]
        }
    }
}

enum ExistingWorkAnalyticsLayout {
    static func chartHeight(categoryCount: Int) -> CGFloat {
        max(215, CGFloat(max(0, categoryCount)) * 30 + 35)
    }

    static func stackCards(width: CGFloat) -> Bool {
        width < 860
    }
}
