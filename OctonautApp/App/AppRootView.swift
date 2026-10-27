import SwiftUI

struct AppRootView: View {
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
#if DEBUG
        if ProcessInfo.processInfo.environment["OCTONAUT_SCREENSHOT"] == "media" {
            OctonautMediaViewer(post: .screenshotGallery)
        } else if ProcessInfo.processInfo.environment["OCTONAUT_SCREENSHOT"] != nil {
            OctonautTabsView(store: OctonautFeatureStore(settings: dependencies.settings, screenshotMode: true))
        } else {
            liveTabs
        }
#else
        liveTabs
#endif
    }

    private var liveTabs: some View {
        OctonautTabsView(
            store: OctonautFeatureStore(
                reddit: dependencies.reddit,
                authenticated: dependencies.authenticated,
                intelligence: dependencies.intelligence,
                settings: dependencies.settings,
                persistence: dependencies.persistence
            ),
            reddit: dependencies.reddit
        )
    }
}

#Preview {
    AppRootView()
        .environment(AppDependencies.preview())
}
