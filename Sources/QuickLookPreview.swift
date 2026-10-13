import QuickLookUI
import SwiftUI

struct QuickLookPreviewSheet: View {
    let url: URL
    let title: String
    var provenance: DocumentProvenance? = nil
    @State private var showingOCRPane = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
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
                QuickLookPreviewRepresentable(url: url)
                if showingOCRPane, let prov = provenance {
                    Divider()
                    ocrDetailView(prov)
                        .frame(width: 340)
                }
            }
        }
        .frame(minWidth: showingOCRPane ? 1040 : 760, minHeight: 640)
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
                        ForEach(prov.pages, id: \.pageNumber) { page in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("第 \(page.pageNumber) 页")
                                        .font(.caption.bold())
                                        .foregroundStyle(AppTheme.blue)
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

