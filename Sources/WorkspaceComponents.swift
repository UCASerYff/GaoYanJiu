import SwiftUI

private struct WorkspaceCardModifier: ViewModifier {
    var cornerRadius: CGFloat
    var padding: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(AppTheme.border))
            .shadow(color: .black.opacity(0.035), radius: 7, y: 3)
    }
}

extension View {
    func workspaceCard(cornerRadius: CGFloat = 14, padding: CGFloat = 16) -> some View {
        modifier(WorkspaceCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

struct WorkspaceSearchField: View {
    let prompt: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).focused(focus)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(AppLocalization.text("清除搜索"))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.border))
        .frame(minWidth: 250, maxWidth: 360)
    }
}

struct SubmissionScopeTabs: View {
    @Binding var selection: SubmissionScope
    let counts: [SubmissionScope: Int]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(SubmissionScope.allCases) { scope in
                Button { selection = scope } label: {
                    HStack(spacing: 5) {
                        Text(scope.title)
                        Text("\(counts[scope] ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(selection == scope ? AppTheme.accent.opacity(0.13) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == scope ? .isSelected : [])
            }
        }
        .padding(4).background(AppTheme.sidebar, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}
