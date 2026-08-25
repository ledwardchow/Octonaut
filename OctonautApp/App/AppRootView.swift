import SwiftUI

struct AppRootView: View {
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
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
