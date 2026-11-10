import SwiftUI

enum PortalPresentation {
    enum State {
        case error, stale, healthy
    }

    static func state(for portal: PortalAccount, now: Date = Date()) -> State {
        if portal.lastError != nil { return .error }
        guard let lastChecked = portal.lastChecked else { return .stale }
        return now.timeIntervalSince(lastChecked) > 86_400 ? .stale : .healthy
    }

    static func hostPath(for portal: PortalAccount) -> String {
        (URL(string: portal.url)?.host ?? portal.name) + "/"
            + (URL(string: portal.url)?.path.split(separator: "/").first.map(String.init) ?? "")
    }

    static func statusText(for portal: PortalAccount, now: Date = Date()) -> String {
        switch state(for: portal, now: now) {
        case .error:
            return AppLocalization.text("同步有错误")
        case .stale:
            return AppLocalization.text("历史状态，需刷新")
        case .healthy:
            guard let lastChecked = portal.lastChecked else { return AppLocalization.text("历史状态，需刷新") }
            return AppLocalization.format("最近检查：%@", Formatters.dateTime.string(from: lastChecked))
        }
    }

    static func accessibilityValue(for portal: PortalAccount, now: Date = Date()) -> String {
        switch state(for: portal, now: now) {
        case .error: AppLocalization.text("同步有错误")
        case .stale: AppLocalization.text("历史状态，需刷新")
        case .healthy: AppLocalization.text("最近同步正常")
        }
    }
}

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
                            let state = PortalPresentation.state(for: portal)
                            HStack(spacing: 9) {
                                Button { openPortal(portal) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(portal.publisherName).font(.callout.weight(.medium)).lineLimit(1)
                                        Text(PortalPresentation.hostPath(for: portal))
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        Text(PortalPresentation.statusText(for: portal))
                                            .font(.caption2).foregroundStyle(state == .error ? AppTheme.clay : .secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .accessibilityValue(PortalPresentation.accessibilityValue(for: portal))
                                .help(AppLocalization.text("重新打开登录窗口"))
                                Button { deletePortal(portal) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                    .disabled(store.isRefreshing).accessibilityLabel(AppLocalization.text("删除门户"))
                                    .help(AppLocalization.text("删除门户"))
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
