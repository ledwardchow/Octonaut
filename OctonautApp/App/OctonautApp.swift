import SwiftUI

@main
struct OctonautApp: App {
    @State private var dependencies: AppDependencies

    init() {
        _dependencies = State(initialValue: AppDependencies.live())
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(dependencies)
                .task {
                    await OctonautImageCache.configure(
                        diskCapacityMB: dependencies.settings.imageCacheLimitMB
                    )
                    await dependencies.accounts.load()
                }
        }
    }
}
