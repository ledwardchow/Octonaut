import SwiftUI

@main
struct LedditApp: App {
    @State private var dependencies: AppDependencies

    init() {
        _dependencies = State(initialValue: AppDependencies.live())
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(dependencies)
                .task {
                    await LedditImageCache.configure(
                        diskCapacityMB: dependencies.settings.imageCacheLimitMB
                    )
                    await dependencies.accounts.load()
                }
        }
    }
}
