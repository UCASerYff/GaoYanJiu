import SwiftUI

struct SubmissionPortalPanel: View {
    @EnvironmentObject private var store: PaperStore
    let openPortal: (PortalAccount) -> Void
    let addPortal: () -> Void
    let deletePortal: (PortalAccount) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(AppLocalization.text("投稿门户"), systemImage: "link")
                    .font(.headline)
                Spacer()
                Button(action: addPortal) { Image(systemName: "plus") }
                    .buttonStyle(.plain).accessibilityLabel(AppLocalization.text("从投稿系统导入"))
            }
            Text(AppLocalization.format("%d 个投稿门户", store.portals.count))
                .font(.caption).foregroundStyle(.secondary)
            if store.portals.isEmpty {
                Text(AppLocalization.text("连接投稿门户，开始整理你的学术成果"))
                    .font(.callout).foregroundStyle(.secondary)
                Button(AppLocalization.text("从投稿系统导入"), action: addPortal)
                    .buttonStyle(.borderedProminent).tint(AppTheme.accent)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(store.portals) { portal in
                            HStack(spacing: 9) {
                                Button { openPortal(portal) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(portal.publisherName).font(.callout.weight(.medium)).lineLimit(1)
                                        Text(portal.lastError == nil ? AppLocalization.text("最近同步正常") : AppLocalization.text("同步有错误"))
                                            .font(.caption2).foregroundStyle(portal.lastError == nil ? .secondary : AppTheme.clay)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                Button { deletePortal(portal) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                    .disabled(store.isRefreshing).accessibilityLabel(AppLocalization.text("删除门户"))
                            }
                            Divider().overlay(AppTheme.border)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Button(AppLocalization.text(store.isRefreshing ? "刷新中" : "刷新全部")) { store.refreshAll() }
                    .disabled(store.isRefreshing)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .workspaceCard(cornerRadius: 14, padding: 16)
    }
}
