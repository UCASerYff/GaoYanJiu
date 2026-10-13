import Foundation
import SQLite3

#if !BACKUP_SAFETY_TEST
#error("Run scripts/test_backup.sh to use the isolated test app and fixture defaults.")
#endif

/// This module-local type shadows Foundation.UserDefaults in the compiled Host
/// sources. All fixture settings remain in memory, including the module domain.
final class UserDefaults {
    static let standard = UserDefaults()
    private var domains: [String: [String: Any]] = [:]
    private(set) var readCount = 0
    private(set) var writeCount = 0

    func persistentDomain(forName name: String) -> [String: Any]? {
        check(name)
        readCount += 1
        return domains[name]
    }

    func setPersistentDomain(_ domain: [String: Any], forName name: String) {
        check(name)
        writeCount += 1
        domains[name] = domain
    }

    private func check(_ name: String) {
        precondition(name == "com.gao.research.tests.backup-safety" ||
                     name == "com.academic-achievement.manager.Research",
                     "Unexpected fixture defaults domain")
    }
}

enum AppDataLocations {
    static var appSupport: URL? {
        ProcessInfo.processInfo.environment["TEST_APP"].map { URL(fileURLWithPath: $0) }
    }
    static var groupContainer: URL? {
        ProcessInfo.processInfo.environment["TEST_GROUP"].map { URL(fileURLWithPath: $0) }
    }
}

@main struct BackupSafetyRegression {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func expect(_ condition: Bool, _ description: String) throws {
        guard condition else { throw Failure(description: description) }
    }

    static func rejects(_ description: String, _ operation: () throws -> Void) throws {
        var rejected = false
        do { try operation() } catch { rejected = true }
        try expect(rejected, description)
    }

    static func sqliteRows(_ source: URL) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(source.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else { throw Failure(description: "Cannot read fixture SQLite") }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT v FROM t ORDER BY rowid", -1, &statement, nil) == SQLITE_OK else {
            throw Failure(description: "Cannot query fixture SQLite")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else {
                throw Failure(description: "Invalid fixture SQLite value")
            }
            rows.append(String(cString: text))
            status = sqlite3_step(statement)
        }
        try expect(status == SQLITE_DONE, "Fixture SQLite query failed")
        return rows
    }

    static func matchingPreferences(_ first: [String: Any], _ second: [String: Any]) -> Bool {
        NSDictionary(dictionary: first).isEqual(to: second)
    }

    static func main() {
        do { try run() }
        catch {
            fputs("FAIL Backup: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    static func run() throws {
        let fm = FileManager.default
        guard let testRoot = ProcessInfo.processInfo.environment["GQ_BACKUP_TEST_ROOT"] else {
            throw Failure(description: "Missing isolated test root; use scripts/test_backup.sh")
        }
        let root = URL(fileURLWithPath: testRoot, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let tmpPath = ProcessInfo.processInfo.environment["TMPDIR"] ?? fm.temporaryDirectory.path
        let temporary = URL(fileURLWithPath: tmpPath, isDirectory: true).resolvingSymlinksInPath()
        try expect(root.resolvingSymlinksInPath().deletingLastPathComponent() == temporary.deletingLastPathComponent(),
                   "Fixtures must remain beside the isolated TMPDIR")
        try expect(Bundle.main.bundleIdentifier == "com.gao.research.tests.backup-safety",
                   "Missing isolated test app bundle")
        let app = root.appendingPathComponent("App"), group = root.appendingPathComponent("Group")
        let jobs = root.appendingPathComponent("Jobs")
        for directory in [app, group] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        setenv("TEST_APP", app.path, 1)
        setenv("TEST_GROUP", group.path, 1)
        setenv("GQNS_RESTORE_ROOT", jobs.path, 1)

        let standardDomain = Bundle.main.bundleIdentifier!
        let moduleDomain = "com.academic-achievement.manager.Research"
        let initialStandard: [String: Any] = ["fixture.language": "en", "fixture.reminders": 7]
        let initialModule: [String: Any] = ["fixture.appearance": "dark", "fixture.enabled": true]
        UserDefaults.standard.setPersistentDomain(initialStandard, forName: standardDomain)
        UserDefaults.standard.setPersistentDomain(initialModule, forName: moduleDomain)

        let attachments = ["paper.pdf": Data("PDF fixture payload".utf8),
                           "paper.docx": Data("Word fixture payload".utf8),
                           "photo.png": Data("Photo fixture payload".utf8)]
        for (name, data) in attachments { try data.write(to: app.appendingPathComponent(name)) }
        let dbURL = group.appendingPathComponent("test.sqlite")
        var db: OpaquePointer?
        try expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK, "Cannot create fixture database")
        defer { if let db { sqlite3_close(db) } }
        try expect(sqlite3_exec(db, "PRAGMA journal_mode=WAL;PRAGMA wal_autocheckpoint=0;CREATE TABLE t (v TEXT);INSERT INTO t VALUES('committed WAL data');", nil, nil, nil) == SQLITE_OK,
                   "Cannot commit fixture WAL data")
        let wal = group.appendingPathComponent("test.sqlite-wal")
        let walData = try Data(contentsOf: wal)
        try expect(!walData.isEmpty, "Fixture must contain an active WAL")

        let archive = root.appendingPathComponent("backup.zip")
        let exported = try AppBackupExport.export(appSupport: app, group: group, destination: archive)
        try expect(exported.fileCount == 6 && exported.zipBytes > 0, "Unexpected export contents")
        let (staged, manifest) = try AppBackupRestore.prepare(archive)
        try expect(manifest.files.count == 5, "Unexpected backup manifest contents")
        try expect(try sqliteRows(staged.appendingPathComponent("AppGroupContainer/test.sqlite")) == ["committed WAL data"],
                   "SQLite snapshot lost committed WAL records")
        for (name, data) in attachments {
            let file = staged.appendingPathComponent("ApplicationSupport-Research/" + name)
            try expect(try Data(contentsOf: file) == data, "Attachment bytes changed in export")
            try expect(try BackupIntegrity.hash(file) == BackupIntegrity.hash(app.appendingPathComponent(name)),
                       "Attachment SHA-256 changed in export")
        }
        let prefsData = try Data(contentsOf: staged.appendingPathComponent("preferences.plist"))
        let exportedPrefs = try PropertyListSerialization.propertyList(from: prefsData, options: [], format: nil) as! [String: [String: Any]]
        try expect(matchingPreferences(exportedPrefs["standard"]!, initialStandard), "Standard fixture preferences not exported")
        try expect(matchingPreferences(exportedPrefs["module"]!, initialModule), "Module fixture preferences not exported")

        sqlite3_close(db)
        db = nil
        let changed = Data("new current fixture data".utf8)
        try changed.write(to: app.appendingPathComponent("paper.pdf"))
        try changed.write(to: group.appendingPathComponent("new-after-backup.txt"))
        UserDefaults.standard.setPersistentDomain(["fixture.language": "zh-Hans"], forName: standardDomain)
        UserDefaults.standard.setPersistentDomain(["fixture.appearance": "light"], forName: moduleDomain)
        try AppBackupRestore.schedule(staged)
        try AppBackupRestore.applyPending()
        for (name, data) in attachments {
            try expect(try Data(contentsOf: app.appendingPathComponent(name)) == data, "Attachment restore failed")
        }
        try expect(try sqliteRows(dbURL) == ["committed WAL data"], "SQLite restore lost WAL records")
        try expect(DailyBackup.integrityCheck(dbURL) == "ok", "Restored database integrity failed")
        try expect(!fm.fileExists(atPath: group.appendingPathComponent("new-after-backup.txt").path), "Unexpected current group file retained")
        try expect(matchingPreferences(UserDefaults.standard.persistentDomain(forName: standardDomain)!, initialStandard), "Standard fixture settings restore failed")
        try expect(matchingPreferences(UserDefaults.standard.persistentDomain(forName: moduleDomain)!, initialModule), "Module fixture settings restore failed")
        try expect(!fm.fileExists(atPath: AppBackupRestore.pending.path) && !fm.fileExists(atPath: staged.path), "Restore staging not removed")
        let safetyCopies = try fm.contentsOfDirectory(at: jobs, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("恢复前原始数据-") }
        try expect(safetyCopies.count == 1, "Original safety copy missing")
        try expect(try Data(contentsOf: safetyCopies[0].appendingPathComponent("ApplicationSupport/paper.pdf")) == changed,
                   "Original pre-restore attachment not retained")
        try expect(try Data(contentsOf: safetyCopies[0].appendingPathComponent("Group-new-after-backup.txt")) == changed,
                   "Original pre-restore group file not retained")

        let archiveHash = try BackupIntegrity.hash(archive)
        try Data("not sqlite".utf8).write(to: group.appendingPathComponent("broken.sqlite"))
        try rejects("Accepted corrupt source database") {
            _ = try AppBackupExport.export(appSupport: app, group: group, destination: archive)
        }
        try expect(try BackupIntegrity.hash(archive) == archiveHash, "Export failure replaced known-good archive")
        try fm.removeItem(at: group.appendingPathComponent("broken.sqlite"))
        try rejects("Accepted missing source directories") {
            _ = try AppBackupExport.export(appSupport: nil, group: nil, destination: archive)
        }
        try expect(try BackupIntegrity.hash(archive) == archiveHash, "Missing sources changed known-good archive")

        let (bad, _) = try AppBackupRestore.prepare(archive)
        try Data("tampered fixture attachment".utf8).write(to: bad.appendingPathComponent("ApplicationSupport-Research/paper.pdf"))
        try rejects("Accepted attachment hash tampering") { _ = try BackupIntegrity.verify(bad) }
        let liveHash = try BackupIntegrity.hash(app.appendingPathComponent("paper.pdf"))
        let settingsWrites = UserDefaults.standard.writeCount
        try AppBackupRestore.schedule(bad)
        try rejects("Applied tampered backup") { try AppBackupRestore.applyPending() }
        try expect(try BackupIntegrity.hash(app.appendingPathComponent("paper.pdf")) == liveHash,
                   "Rejected restore changed current data")
        try expect(UserDefaults.standard.writeCount == settingsWrites, "Rejected restore changed fixture settings")

        let (badDatabase, originalManifest) = try AppBackupRestore.prepare(archive)
        let corruptFile = badDatabase.appendingPathComponent("AppGroupContainer/test.sqlite")
        try Data("corrupt database with a matching checksum".utf8).write(to: corruptFile)
        var repairedManifest = originalManifest
        repairedManifest.files["AppGroupContainer/test.sqlite"] = try BackupIntegrity.hash(corruptFile)
        try JSONEncoder().encode(repairedManifest).write(to: badDatabase.appendingPathComponent("gqns-manifest.json"))
        try rejects("Accepted corrupt database after manifest checksum repair") { _ = try BackupIntegrity.verify(badDatabase) }

        let leftovers = try fm.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("gqns-export-") }
        try expect(leftovers.isEmpty, "Export temporary files were not cleaned")
        print("PASS Backup: committed WAL records; PDF/Word/photo SHA-256; export/preview/restore; memory-only settings; safety copies; missing/corrupt sources preserve archive; attachment/database tampering rejected; isolated temp cleanup")
    }
}
