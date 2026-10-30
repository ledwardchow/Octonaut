import SwiftUI

@main
struct OctonautMacApp: App {
    @AppStorage(AppIconChoice.preferenceKey) private var appIconChoice = AppIconChoice.original.rawValue
    @State private var dependencies: AppDependencies

    init() {
#if DEBUG
        if ProcessInfo.processInfo.environment["OCTONAUT_SCREENSHOT"] != nil {
            _dependencies = State(initialValue: AppDependencies.preview())
        } else {
            _dependencies = State(initialValue: AppDependencies.live())
        }
#else
        _dependencies = State(initialValue: AppDependencies.live())
#endif
    }

    var body: some Scene {
        WindowGroup("Octonaut") {
            MacRootView(dependencies: dependencies)
                .environment(dependencies)
                .onAppear { AppIconChoice.applyDockIcon(appIconChoice) }
                .onChange(of: appIconChoice) { _, value in AppIconChoice.applyDockIcon(value) }
                .id(dependencies.resetGeneration)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1240, height: 780)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            SidebarCommands()
            CommandMenu("Posts") {
                Button("New Post") {
                    NotificationCenter.default.post(name: .octonautMacNewPost, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Refresh") {
                    NotificationCenter.default.post(name: .octonautMacRefresh, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Search") {
                    NotificationCenter.default.post(name: .octonautMacShowSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Divider()

                Button("Home") {
                    NotificationCenter.default.post(
                        name: .octonautMacSelectFeed,
                        object: FeedDescriptorModel.home
                    )
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Popular") {
                    NotificationCenter.default.post(
                        name: .octonautMacSelectFeed,
                        object: FeedDescriptorModel.popular
                    )
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("All") {
                    NotificationCenter.default.post(
                        name: .octonautMacSelectFeed,
                        object: FeedDescriptorModel.all
                    )
                }
                .keyboardShortcut("3", modifiers: .command)
            }
        }

        Settings {
            MacSettingsView(settings: dependencies.settings)
                .environment(dependencies)
        }
    }
}

extension Notification.Name {
    static let octonautMacNewPost = Notification.Name("OctonautMac.newPost")
    static let octonautMacRefresh = Notification.Name("OctonautMac.refresh")
    static let octonautMacShowSearch = Notification.Name("OctonautMac.showSearch")
    static let octonautMacSelectFeed = Notification.Name("OctonautMac.selectFeed")
}
