import Foundation

/// One production-source compile, two separate CLI fixture processes. These
/// paths never create an application, window, or real preference/data domain.
@main enum ResearchIntegrationRegression {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("one directed case required") }
        switch CommandLine.arguments[1] {
        case "funding.readonly": ResearchTrashPersistenceRegression.main()
        case "startup": try await StartupMaintenanceRegression.main()
        default: fatalError("unsupported directed integration case")
        }
    }
}
