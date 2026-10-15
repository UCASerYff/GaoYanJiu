import QuickLookUI
import SwiftUI
import PDFKit
import CryptoKit

struct QuickLookPreviewSheet: View {
    let url: URL
    let title: String
    var provenance: DocumentProvenance? = nil
    var originalPDFURL: URL? = nil
    var initialPage: Int? = nil
    @State private var showingOCRPane = false
    @State private var selectedPage: Int?
    @State private var verifiedPDFData: Data?
    @State private var sourcePageCount = 0
    @State private var pageNavigationMessage = "正在核对原 PDF…"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if selectedPage != nil {
                    Button("返回附件预览") { selectedPage = nil }
                        .buttonStyle(.bordered)
                }
                if let prov = provenance, !prov.pages.isEmpty || prov.ocrEngine != nil {
                    Button {
                        showingOCRPane.toggle()
                    } label: {
                        Label(showingOCRPane ? AppLocalization.text("隐藏OCR文本") : AppLocalization.text("查看OCR识别文本"), systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                }
                Button(AppLocalization.text("完成")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            HStack(spacing: 0) {
                if let selectedPage, let verifiedPDFData {
                    SourcePDFPreview(data: verifiedPDFData, sourceID: provenance?.originalSHA256 ?? "", pageNumber: selectedPage)
                } else {
                    QuickLookPreviewRepresentable(url: url)
                }
                if showingOCRPane, let prov = provenance {
                    Divider()
                    ocrDetailView(prov)
                        .frame(width: 340)
                }
            }
        }
        .frame(minWidth: showingOCRPane ? 1040 : 760, minHeight: 640)
        .task(id: url) { await verifySourcePDF() }
    }

    private func verifySourcePDF() async {
        guard let provenance, !provenance.pages.isEmpty else { return }
        let candidate = originalPDFURL ?? (url.pathExtension.lowercased() == "pdf" ? url : nil)
        guard let candidate, candidate.pathExtension.lowercased() == "pdf" else {
            pageNavigationMessage = "没有可核验的原 PDF，页码仅作来源记录。"
            return
        }
        let expected = provenance.originalSHA256.lowercased()
        let snapshot = await Task.detached(priority: .utility) { () -> (Data, Int)? in
            guard let data = try? GaoActionFileAccess.readPrivateData(at: candidate, maximumBytes: 128 * 1_048_576),
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected,
                  let document = PDFDocument(data: data) else { return nil }
            return (data, document.pageCount)
        }.value
        guard let (data, count) = snapshot, count > 0 else {
            pageNavigationMessage = "原 PDF 已改变、无法读取或超过 128 MiB 页码预览上限，暂不能跳转。"
            return
        }
        // Display these exact verified bytes throughout this sheet. Reopening
        // the source URL later could show a file changed by an external editor.
        verifiedPDFData = data
        sourcePageCount = count
        pageNavigationMessage = "选择页码可跳到已核验的原 PDF。"
        if let initialPage, (1...count).contains(initialPage) {
            selectedPage = initialPage
            showingOCRPane = true
        }
    }

    private func ocrDetailView(_ prov: DocumentProvenance) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("OCR 识别详情")
                    .font(.headline)
                if let engine = prov.ocrEngine {
                    Text("引擎：\(engine)\(prov.ocrVersion.map { " v" + $0 } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let decl = prov.sourceDeclaration {
                    Text("来源：\(decl)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("原件摘要：\(prov.originalSHA256.prefix(12))…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Text(pageNavigationMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if prov.pages.isEmpty {
                        Text("无分页识别内容")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(prov.pages.enumerated()), id: \.offset) { _, page in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Button(page.pageNumber > 0 ? "第 \(page.pageNumber) 页 ↗" : "页码未知") {
                                        selectedPage = page.pageNumber
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption.bold())
                                    .disabled(verifiedPDFData == nil || page.pageNumber < 1 || page.pageNumber > sourcePageCount)
                                    Spacer()
                                    if let status = page.status {
                                        Text(status == "completed" ? "完成" : (status == "failed" ? "失败" : status))
                                            .font(.caption2)
                                            .foregroundStyle(status == "failed" ? .red : .secondary)
                                    }
                                    if let conf = page.confidence {
                                        Text(String(format: "%.0f%%", conf * 100))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(page.text ?? "（未提取到文字）")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SourcePDFPreview: NSViewRepresentable {
    let data: Data
    let sourceID: String
    let pageNumber: Int

    final class Coordinator { var target: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.setAccessibilityLabel(AppLocalization.text("原 PDF 页码预览"))
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        let target = "\(sourceID)#\(pageNumber)"
        guard context.coordinator.target != target else { return }
        if context.coordinator.target == nil || context.coordinator.target?.hasPrefix(sourceID + "#") != true {
            view.document = PDFDocument(data: data)
        }
        guard pageNumber > 0, let page = view.document?.page(at: pageNumber - 1) else { return }
        view.go(to: page)
        context.coordinator.target = target
    }
}

private struct QuickLookPreviewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.setAccessibilityLabel(AppLocalization.text("快速预览"))
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as NSURL
    }
}

