import SwiftUI

struct RecycleBinView: View {
    @EnvironmentObject private var store: PaperStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEmpty = false
    @State private var pendingPermanentDeleteID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppLocalization.text("回收站"))
                        .font(.title2.weight(.semibold))
                    Text(AppLocalization.text("删除的记录和文件保留30天，可恢复到原位置。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !store.trashItems.isEmpty {
                    Button(AppLocalization.text("清空回收站"), role: .destructive) { confirmEmpty = true }
                }
                Button(AppLocalization.text("完成")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()

            if store.trashItems.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "trash")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(AppLocalization.text("回收站为空"))
                        .font(.title3.weight(.semibold))
                    Text(AppLocalization.text("删除论文、成果、项目、文件夹、文件、证书或资金记录后，会先出现在这里。"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.orderedTrashItems) { item in
                            HStack(spacing: 14) {
                                Image(systemName: item.kind.symbol)
                                    .foregroundStyle(AppTheme.blue)
                                    .frame(width: 42, height: 42)
                                    .background(AppTheme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title)
                                        .font(.headline)
                                        .lineLimit(2)
                                    HStack(spacing: 8) {
                                        Text(item.kind.title)
                                        Text(AppLocalization.format("删除于 %@", Formatters.dateTime.string(from: item.deletedAt)))
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(AppLocalization.text("恢复")) { store.restoreTrashItem(id: item.id) }
                                    .buttonStyle(.borderedProminent)
                                Button(AppLocalization.text("彻底删除"), role: .destructive) {
                                    pendingPermanentDeleteID = item.id
                                }
                            }
                            .padding(14)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.07)))
                            .listHoverHighlight(cornerRadius: 11)
                        }
                    }
                    .padding(18)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .alert(AppLocalization.text("清空回收站？"), isPresented: $confirmEmpty) {
            Button(AppLocalization.text("取消"), role: .cancel) {}
            Button(AppLocalization.text("彻底删除"), role: .destructive) { store.emptyTrash() }
        } message: {
            Text(AppLocalization.text("回收站中的全部记录和文件将永久删除，无法恢复。"))
        }
        .alert(AppLocalization.text("彻底删除该记录？"), isPresented: Binding(
            get: { pendingPermanentDeleteID != nil },
            set: { if !$0 { pendingPermanentDeleteID = nil } }
        )) {
            Button(AppLocalization.text("取消"), role: .cancel) { pendingPermanentDeleteID = nil }
            Button(AppLocalization.text("彻底删除"), role: .destructive) {
                if let id = pendingPermanentDeleteID {
                    store.permanentlyDeleteTrashItem(id: id)
                }
                pendingPermanentDeleteID = nil
            }
        } message: {
            if let id = pendingPermanentDeleteID,
               let item = store.trashItems.first(where: { $0.id == id }) {
                Text(AppLocalization.format("“%@”将被永久删除，无法恢复。", item.title))
            } else {
                Text(AppLocalization.text("该记录将被永久删除，无法恢复。"))
            }
        }
    }
}
