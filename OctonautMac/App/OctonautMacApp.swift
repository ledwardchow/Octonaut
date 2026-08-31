import SwiftUI

@main
struct OctonautMacApp: App {
    @State private var dependencies: AppDependencies

    init() {
        _dependencies = State(initialValue: AppDependencies.live())
    }

    var body: some Scene {
        WindowGroup("Octonaut") {
            MacRootView(dependencies: dependencies)
                .environment(dependencies)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1240, height: 780)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            SidebarCommands()
            CommandMenu("Posts") {
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
    static let octonautMacRefresh = Notification.Name("OctonautMac.refresh")
    static let octonautMacShowSearch = Notification.Name("OctonautMac.showSearch")
    static let octonautMacSelectFeed = Notification.Name("OctonautMac.selectFeed")
}
