import Foundation

enum MacSidebarSelection: Hashable {
    case feed(FeedDescriptorModel)
    case search
    case inbox
    case accounts
}

extension FeedDescriptorModel {
    var macTitle: String {
        switch kind {
        case .home: "Home"
        case .popular: "Popular"
        case .all: "All"
        case .community: "r/\(name)"
        case .multireddit: name
        }
    }
}
