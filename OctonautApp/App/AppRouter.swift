import Foundation
import Observation

@MainActor
@Observable
final class AppRouter {
    var selectedTab: AppTab
    private(set) var paths: [AppTab: [AppRoute]]
    var presentedSheet: SheetRoute?

    init(selectedTab: AppTab = .posts) {
        self.selectedTab = selectedTab
        paths = Dictionary(uniqueKeysWithValues: AppTab.allCases.map { ($0, []) })
    }

    var currentPath: [AppRoute] {
        get { paths[selectedTab, default: []] }
        set { paths[selectedTab] = newValue }
    }

    func push(_ route: AppRoute, on tab: AppTab? = nil) {
        let tab = tab ?? selectedTab
        paths[tab, default: []].append(route)
    }

    func pop(on tab: AppTab? = nil) {
        let tab = tab ?? selectedTab
        guard !(paths[tab, default: []].isEmpty) else { return }
        paths[tab]?.removeLast()
    }

    func popToRoot(on tab: AppTab? = nil) {
        paths[tab ?? selectedTab] = []
    }

    func present(_ sheet: SheetRoute) {
        presentedSheet = sheet
    }

    func dismissSheet() {
        presentedSheet = nil
    }
}
