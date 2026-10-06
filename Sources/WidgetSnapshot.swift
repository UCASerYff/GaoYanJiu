import Foundation

struct ResearchWidgetSnapshot: Codable {
    static let groupID = "5G96498KGJ.com.academic-achievement.manager"
    struct Paper: Codable, Identifiable, Equatable {
        let id: String
        let title: String
        let number: String
        let since: Date
        let terminal: Bool
        func days(at date: Date) -> Int {
            max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: since), to: Calendar.current.startOfDay(for: date)).day ?? 0)
        }
    }
    struct Count: Codable, Identifiable, Equatable {
        let id: String
        let label: String
        let count: Int
    }
    let updatedAt: Date
    let english: Bool
    let papers: [Paper]
    let categories: [Count]
    let authors: [Count]
    let totalWorks: Int
    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent("statistics.json")
    }
}
