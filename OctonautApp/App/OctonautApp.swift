import SwiftUI

@main
struct OctonautApp: App {
    @State private var dependencies: AppDependencies

    init() {
#if DEBUG
        if NSClassFromString("XCTestCase") != nil {
            // The test host must not start live Reddit requests in the background.
            _dependencies = State(initialValue: AppDependencies.preview())
        } else if ProcessInfo.processInfo.environment["OCTONAUT_SCREENSHOT"] != nil {
            let preview = AppDependencies.preview()
            preview.settings.customFeeds = [
                CustomFeed(name: "Apple & Swift", communities: ["apple", "swift"]),
                CustomFeed(name: "Photography", communities: ["iphone", "photography"])
            ]
            _dependencies = State(initialValue: preview)
        } else {
            _dependencies = State(initialValue: AppDependencies.live())
        }
#else
        _dependencies = State(initialValue: AppDependencies.live())
#endif
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(dependencies)
                .id(dependencies.resetGeneration)
                .task {
                    await OctonautAudioSession.prepareForMutedFeedPlayback()
                    await OctonautImageCache.configure(
                        diskCapacityMB: dependencies.settings.imageCacheLimitMB
                    )
#if DEBUG
                    if ProcessInfo.processInfo.environment["OCTONAUT_SCREENSHOT"] == "blocked-users" {
                        try? await dependencies.persistence.saveAccount(Account(username: "example_reader", health: .healthy))
                    }
#endif
                    await dependencies.accounts.load()
                }
        }
    }
}
