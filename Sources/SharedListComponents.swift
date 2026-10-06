import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - V4.6 batch-Q2 共享列表组件

/// 通用拖动排序 DropDelegate（泛化自 Views / ManualAndExistingViews / DocumentLibraryViews
/// 三份逐行重复的 ReorderDropDelegate）。
/// 拖动经过目标时通过 `move` 闭包做内存内换位（store 侧一律 persist:false），
/// `performDrop` 落点确定后由 `persist` 闭包统一落盘（store.save()）。
struct ReorderDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggedID: String?
    /// 拖动经过目标时调用：把 sourceID 移到 targetID 之前（只改内存，不落盘）。
    let move: (_ sourceID: String, _ targetID: String) -> Void
    /// 拖动结束、落点确定后调用：统一持久化。
    let persist: () -> Void

    init(
        targetID: String,
        draggedID: Binding<String?>,
        move: @escaping (_ sourceID: String, _ targetID: String) -> Void,
        persist: @escaping () -> Void
    ) {
        self.targetID = targetID
        _draggedID = draggedID
        self.move = move
        self.persist = persist
    }

    func dropEntered(info: DropInfo) {
        guard let draggedID, draggedID != targetID else { return }
        move(draggedID, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        persist()
        return true
    }
}

extension ReorderDropDelegate {
    /// 论文列表（Views.swift 的 PaperReorderDropDelegate 留给父代理接入此工厂）。
    static func paper(targetID: String, draggedID: Binding<String?>, store: PaperStore) -> ReorderDropDelegate {
        ReorderDropDelegate(
            targetID: targetID,
            draggedID: draggedID,
            move: { store.movePaper(sourceID: $0, before: $1, persist: false) },
            persist: { store.save() }
        )
    }

    /// 成果列表。
    static func existingWork(targetID: String, draggedID: Binding<String?>, store: PaperStore) -> ReorderDropDelegate {
        ReorderDropDelegate(
            targetID: targetID,
            draggedID: draggedID,
            move: { store.moveExistingWork(sourceID: $0, before: $1, persist: false) },
            persist: { store.save() }
        )
    }

    /// 文档文件夹网格。
    static func documentFolder(targetID: String, draggedID: Binding<String?>, store: PaperStore) -> ReorderDropDelegate {
        ReorderDropDelegate(
            targetID: targetID,
            draggedID: draggedID,
            move: { store.moveDocumentFolder(sourceID: $0, before: $1, persist: false) },
            persist: { store.save() }
        )
    }

    /// 项目列表。isEnabled 为 false 时（如搜索态）忽略拖动经过，保持既有 UX。
    static func project(
        targetID: String,
        draggedID: Binding<String?>,
        store: PaperStore,
        isEnabled: Bool = true
    ) -> ReorderDropDelegate {
        ReorderDropDelegate(
            targetID: targetID,
            draggedID: draggedID,
            move: { sourceID, targetID in
                guard isEnabled else { return }
                store.moveProject(sourceID: sourceID, before: targetID, persist: false)
            },
            persist: { store.save() }
        )
    }

    /// 文件夹内的资料库文件。isEnabled 为 false 时（标签排序/搜索/标签筛选态）忽略拖动经过。
    static func managedDocument(
        targetID: String,
        draggedID: Binding<String?>,
        store: PaperStore,
        isEnabled: Bool = true
    ) -> ReorderDropDelegate {
        ReorderDropDelegate(
            targetID: targetID,
            draggedID: draggedID,
            move: { sourceID, targetID in
                guard isEnabled else { return }
                store.moveManagedDocument(sourceID: sourceID, before: targetID, persist: false)
            },
            persist: { store.save() }
        )
    }
}

/// 统一空状态：图标 / 标题 / 副标题 / 可选按钮四参。
/// 标题、副标题、按钮文案由调用方先经 AppLocalization 处理。
/// `embedded = true` 时省略外层水平/底部留白，用于已自带 padding 的容器（如资金面板）。
struct ListEmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var buttonTitle: String? = nil
    var buttonAction: (() -> Void)? = nil
    var embedded = false

    var body: some View {
        VStack(spacing: 17) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(AppTheme.blue)
                .frame(width: 72, height: 72)
                .background(AppTheme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 23, weight: .semibold))
            Text(subtitle)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            if let buttonTitle, let buttonAction {
                Button(action: buttonAction) {
                    Label(buttonTitle, systemImage: "plus.circle.fill")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(42)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07)))
        .padding(.horizontal, embedded ? 0 : 24)
        .padding(.bottom, embedded ? 0 : 24)
    }
}

/// 访达文件拖放导入：把文件 URL 落到指定文档文件夹，
/// 复用 store.importDocuments 既有路径（含格式过滤与失败回滚）。
struct FinderFileDropDelegate: DropDelegate {
    let store: PaperStore
    let folderID: String

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in providers {
                guard let item = try? await provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier,
                    options: nil
                ) else { continue }
                if let url = item as? URL {
                    urls.append(url)
                } else if let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            do {
                let count = try await store.importDocuments(from: urls, into: folderID)
                if count == 0 {
                    store.lastError = AppLocalization.text("没有可导入的受支持文件。")
                }
            } catch {
                store.lastError = AppLocalization.format("文件上传失败：%@", error.localizedDescription)
            }
        }
        return true
    }
}

private struct ListHoverHighlight: ViewModifier {
    @State private var isHovering = false
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(isHovering ? 0.05 : 0))
                    .allowsHitTesting(false)
            )
            .onHover { hovering in
                guard hovering != isHovering else { return }
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}

extension View {
    /// 列表卡片 / 表格行的统一悬停反馈：背景淡色高亮 + 手型光标。
    func listHoverHighlight(cornerRadius: CGFloat = 12) -> some View {
        modifier(ListHoverHighlight(cornerRadius: cornerRadius))
    }
}
