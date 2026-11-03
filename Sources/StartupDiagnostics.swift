import Foundation
import Darwin

/// Privacy-safe phase events. Durations use global CLOCK_MONOTONIC; no wall-clock or
/// "cold boot" label is inferred from a fast empty window or a process restart.
/// No research fields, filenames, credentials or user data are written here.
public enum ResearchStartupDiagnostics {
    static let allowedPhases: Set<String> = [
        "host-entry", "pending-restore-finished", "store-initializing", "repository-read-finished",
        "library-read-ready", "library-read-unavailable", "widget-publication-ready", "widget-publication-pending",
        "store-initialized", "store-unavailable", "content-first-appeared", "startup-data-ready",
        "daily-backup-worker-start", "daily-backup-created", "daily-backup-alreadyExistsNotRevalidated", "daily-backup-failed",
    ]
    private struct Event: Codable {
        let phase: String
        let monotonicSeconds: TimeInterval
        let elapsedSeconds: TimeInterval?
        let mainThread: Bool
    }
    private static let lock = NSLock()
    private static var events: [Event] = []
    private static var libraryReady = false
    private static var widgetReady = false
    private static var contentAppeared = false
    private static var startupReadyRecorded = false
    // Disabled in maintenance commands and isolated CLI tests. Only the GUI
    // host enables it; tests must explicitly supply their own private directory.
    private static var privateFile: ResearchStartupDiagnosticsFile?
    /// Same boot-global clock as the coordinator's CLOCK_MONOTONIC measurement.
    public static func monotonicTime() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
    public static func mark(_ phase: String, elapsed: TimeInterval? = nil) {
        guard allowedPhases.contains(phase), elapsed.map({ $0.isFinite && $0 >= 0 }) ?? true else { return }
        let event = Event(phase: phase, monotonicSeconds: monotonicTime(),
                          elapsedSeconds: elapsed, mainThread: Thread.isMainThread)
        lock.lock()
        // Startup measurements are bounded, including later read retries.
        if events.count < 128 { events.append(event) }
        if phase == "library-read-ready" { libraryReady = true }
        if phase == "library-read-unavailable" { libraryReady = false }
        if phase == "widget-publication-ready" { widgetReady = true }
        if phase == "widget-publication-pending" { widgetReady = false }
        if phase == "content-first-appeared" { contentAppeared = true }
        let dataReady = libraryReady && widgetReady && contentAppeared && !startupReadyRecorded
        if dataReady { startupReadyRecorded = true }
        let output = privateFile
        lock.unlock()
        output?.enqueue(snapshot())
        NSLog("Research startup phase=%@ monotonic=%.6f elapsed=%.6f main=%d", phase,
              event.monotonicSeconds, elapsed ?? -1, event.mainThread ? 1 : 0)
        // This is deliberately later than a blank window appearing. A failed
        // library read or pending widget publication cannot produce this event.
        if dataReady { mark("startup-data-ready") }
    }
    /// File IO is coalesced on a utility queue, outside startup's main actor.
    @discardableResult public static func enablePrivateFileOutput(appVersion: String, build: String, directory: URL? = nil) -> URL {
        lock.lock()
        if let existing = privateFile { lock.unlock(); return existing.fileURL }
        let output = ResearchStartupDiagnosticsFile(directory: directory ?? ResearchStartupDiagnosticsFile.defaultDirectory,
                                                   appVersion: appVersion, build: build)
        privateFile = output
        lock.unlock()
        output.enqueue(snapshot())
        return output.fileURL
    }
    /// Normal Cmd-Q waits only for the bounded timing file, never a business backup.
    public static func flushPrivateFileOutput() {
        lock.lock(); let output = privateFile; lock.unlock()
        output?.flush()
    }
    /// Read-only maintenance path; never constructs PaperStore or enables a writer.
    public static func readPrivateFile(processID: Int32) throws -> Data {
        try ResearchStartupDiagnosticsFile.readNewest(directory: ResearchStartupDiagnosticsFile.defaultDirectory, processID: processID)
    }
    public static func snapshot() -> Data {
        lock.lock(); let captured = events; lock.unlock()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(captured)) ?? Data("[]".utf8)
    }
}
