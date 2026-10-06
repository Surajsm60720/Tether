import SwiftUI

struct WelcomeView: View {
    @Bindable var store: HostStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(TetherType.hero)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.tether.accentText)
            Text(L10n.welcomeTitle)
                .font(TetherType.title)
            Text(L10n.welcomeBody)
                .font(TetherType.body)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Not now") { dismiss() }
                Button(L10n.addFolder) {
                    store.addFolder()
                    if !store.shares.isEmpty { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.tether.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 420)
    }
}
