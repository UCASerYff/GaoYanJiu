import Foundation
import PDFKit

enum DocumentTextExtractor {
    private static let maximumCharacters = 200_000

    static func extractText(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let text: String?
        switch ext {
        case "pdf":
            text = PDFDocument(url: url)?.string
        case "docx":
            text = officeOpenXMLText(for: url, patterns: ["word/document.xml", "word/header*.xml", "word/footer*.xml"])
        case "pptx":
            text = officeOpenXMLText(for: url, patterns: ["ppt/slides/*.xml", "ppt/notesSlides/*.xml"])
        case "xlsx":
            text = officeOpenXMLText(for: url, patterns: ["xl/sharedStrings.xml", "xl/worksheets/*.xml"])
        case "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "rtf":
            text = readTextFile(url)
        default:
            text = spotlightText(for: url)
        }
        guard let normalized = text?
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else { return nil }
        return String(normalized.prefix(maximumCharacters))
    }

    private static func readTextFile(_ url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        if let text = try? String(contentsOf: url, encoding: .utf16) { return text }
        return nil
    }

    private static func spotlightText(for url: URL) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdls")
        process.arguments = ["-raw", "-name", "kMDItemTextContent", url.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value == "(null)" ? nil : value
        } catch {
            return nil
        }
    }

    private static func officeOpenXMLText(for url: URL, patterns: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path] + patterns
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return spotlightText(for: url) }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard var xml = String(data: data, encoding: .utf8) else { return spotlightText(for: url) }
            xml = xml.replacingOccurrences(of: "</w:p>", with: "\n")
                .replacingOccurrences(of: "</a:p>", with: "\n")
                .replacingOccurrences(of: "</row>", with: "\n")
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
            return xml
        } catch {
            return spotlightText(for: url)
        }
    }
}

// MARK: - 全文索引（DocumentLibraryStore 的后台索引职责）

@MainActor
extension DocumentLibraryStore {
    func indexUnindexedDocumentsIfNeeded() {
        let ids = documents.filter { $0.contentIndexedAt == nil }.map(\.id)
        guard !ids.isEmpty else { return }
        rebuildDocumentSearchIndex(documentIDs: Set(ids), userInitiated: false)
    }

    func rebuildDocumentSearchIndex() {
        rebuildDocumentSearchIndex(documentIDs: Set(documents.map(\.id)), userInitiated: true)
    }

    private func rebuildDocumentSearchIndex(documentIDs: Set<String>, userInitiated: Bool) {
        guard !isIndexing else { return }
        let targets = documents.compactMap { document -> (String, URL)? in
            guard documentIDs.contains(document.id) else { return nil }
            return (document.id, managedDocumentURL(document))
        }
        guard !targets.isEmpty else {
            if userInitiated { indexingMessage = AppLocalization.text("没有需要建立索引的文件。") }
            return
        }
        isIndexing = true
        indexingMessage = AppLocalization.format("正在为 %d 个文件建立全文索引…", targets.count)
        Task {
            let results = await Task.detached(priority: .utility) {
                targets.map { id, url in (id, DocumentTextExtractor.extractText(from: url)) }
            }.value
            let now = Date()
            var indexed = 0
            for (id, text) in results {
                guard let index = documents.firstIndex(where: { $0.id == id }) else { continue }
                documents[index].contentText = text
                documents[index].contentIndexedAt = now
                if text?.isEmpty == false { indexed += 1 }
            }
            isIndexing = false
            indexingMessage = AppLocalization.format("全文索引已完成：%d 个文件可搜索正文。", indexed)
            persist()
        }
    }
}

// MARK: - PaperStore 转发扩展

@MainActor
extension PaperStore {
    func indexUnindexedDocumentsIfNeeded() {
        documentLibrary.indexUnindexedDocumentsIfNeeded()
    }

    func rebuildDocumentSearchIndex() {
        documentLibrary.rebuildDocumentSearchIndex()
    }
}
