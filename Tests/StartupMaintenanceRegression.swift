import Foundation

/// CLI-only, isolated tests of the actual startup readiness recorder.
/// Compile with production Sources. This never constructs PaperStore,
/// NSApplication or a production data root.
#if !RESEARCH_INTEGRATION_COMBINED
@main
#endif
enum StartupMaintenanceRegression {
    struct Failed: Error { let message: String }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failed(message: message) }
    }
    static func main() async throws {
        guard let raw = ProcessInfo.processInfo.environment["GAO_STARTUP_REGRESSION_ROOT"],
              raw.hasPrefix("/private/tmp/"), raw.contains(".noindex/"),
              ProcessInfo.processInfo.environment["GAO_RESEARCH_DATA_DIR"]?.hasPrefix(raw) == true else {
            throw Failed(message: "Isolated private noindex fixture root and data override required")
        }
        let root = URL(fileURLWithPath: raw, isDirectory: true)
        let fm = FileManager.default
        try require(!fm.fileExists(atPath: root.path), "Fixture root must be new")
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }

        ResearchStartupDiagnostics.mark("content-first-appeared")
        func phases() throws -> [String] {
            let events = try JSONSerialization.jsonObject(with: ResearchStartupDiagnostics.snapshot()) as! [[String: Any]]
            return events.compactMap { $0["phase"] as? String }
        }
        try require(!phases().contains("startup-data-ready"), "Blank window reported ready")
        ResearchStartupDiagnostics.mark("library-read-ready")
        ResearchStartupDiagnostics.mark("widget-publication-pending")
        try require(!phases().contains("startup-data-ready"), "Pending widget reported ready")
        ResearchStartupDiagnostics.mark("widget-publication-ready")
        try require(phases().filter { $0 == "startup-data-ready" }.count == 1, "Full readiness event missing")
        ResearchStartupDiagnostics.mark("content-first-appeared")
        try require(phases().filter { $0 == "startup-data-ready" }.count == 1, "Readiness duplicated on window reopen")
        print("PASS DataReady requires loaded data + successful widget publication + real content appearance")
        print("Startup maintenance isolated regression complete; no application or smoke test launched.")
    }
}
