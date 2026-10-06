import SwiftUI

@MainActor
struct MacSettingsView: View {
    @Bindable var settings: SettingsStore
    @Environment(AppDependencies.self) private var dependencies
    @State private var showingAppReset = false
    @State private var isResetting = false
    @State private var resetNotice: AppResetNotice?

    var body: some View {
        TabView {
            Form {
                Picker("Feed layout", selection: $settings.feedLayout) {
                    Text("Media cards").tag(FeedLayout.full)
                    Text("Compact rows").tag(FeedLayout.compact)
                }
                Toggle("Show post flair", isOn: $settings.showPostFlair)
                Toggle("Hide seen posts", isOn: $settings.hideSeenPosts)
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                AppIconPicker()
                Toggle("Blur spoilers", isOn: $settings.blurSpoilers)
                Toggle("Blur NSFW media", isOn: $settings.blurNSFWMedia)
            }
            .formStyle(.grouped)
            .tabItem { Label("Appearance", systemImage: "paintbrush") }

            // ponytail: Intelligence, pure black, filter count, link handling and cache-size
            // settings are hidden on Mac until the Mac app applies them.
            Form {
                Toggle("Collect local usage statistics", isOn: $settings.collectLocalUsageStatistics)
                Section("Reset") {
                    Button("Reset App", role: .destructive) {
                        showingAppReset = true
                    }
                    .disabled(isResetting)
                    Text("Removes accounts, Keychain credentials, drafts, preferences, caches, statistics, and synced custom feeds.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            Form {
                Section("Privacy and Terms") {
                    LegalDocumentLinks()
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 390)
        .padding()
        .confirmationDialog(
            "Reset Octonaut?",
            isPresented: $showingAppReset,
            titleVisibility: .visible
        ) {
            Button("Reset App", role: .destructive) {
                Task { await resetApp() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all Octonaut data from this Mac and deletes synced custom feeds from iCloud. You will need to sign in again.")
        }
        .alert(item: $resetNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func resetApp() async {
        isResetting = true
        defer { isResetting = false }
        do {
            try await dependencies.resetAllData()
            resetNotice = AppResetNotice(
                title: "Octonaut Reset",
                message: "All app data was removed. You can now sign in again."
            )
        } catch {
            resetNotice = AppResetNotice(title: "Reset Incomplete", message: error.localizedDescription)
        }
    }
}

private struct AppResetNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
