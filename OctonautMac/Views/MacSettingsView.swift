import SwiftUI

@MainActor
struct MacSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        TabView {
            Form {
                Picker("Feed layout", selection: $settings.feedLayout) {
                    Text("Media cards").tag(FeedLayout.full)
                    Text("Compact rows").tag(FeedLayout.compact)
                }
                Toggle("Show post flair", isOn: $settings.showPostFlair)
                Toggle("Hide seen posts", isOn: $settings.hideSeenPosts)
                Toggle("Show filter count", isOn: $settings.showFilterCount)
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Toggle("Blur spoilers", isOn: $settings.blurSpoilers)
                Toggle("Blur NSFW media", isOn: $settings.blurNSFWMedia)
                Toggle("Use pure black background", isOn: $settings.pureBlackBackground)
            }
            .formStyle(.grouped)
            .tabItem { Label("Appearance", systemImage: "paintbrush") }

            Form {
                Picker("Summary provider", selection: $settings.summaryProvider) {
                    ForEach(SummaryProvider.allCases, id: \.self) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                Toggle("Show post summaries", isOn: $settings.showPostSummaries)
                Toggle("Show comment summaries", isOn: $settings.showCommentSummaries)
                TextField("Endpoint", text: $settings.summaryEndpoint)
                TextField("Model", text: $settings.summaryModel)
            }
            .formStyle(.grouped)
            .tabItem { Label("Intelligence", systemImage: "sparkles") }

            Form {
                Toggle(
                    "Open Reddit links in Octonaut",
                    isOn: $settings.openRedditLinksInOctonaut
                )
                Toggle("Collect local usage statistics", isOn: $settings.collectLocalUsageStatistics)
                Stepper(
                    "Image cache: \(settings.imageCacheLimitMB) MB",
                    value: $settings.imageCacheLimitMB,
                    in: 100...2_000,
                    step: 100
                )
            }
            .formStyle(.grouped)
            .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 560, height: 390)
        .padding()
    }
}
