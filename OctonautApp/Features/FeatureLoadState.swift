import SwiftUI

enum OctonautLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case empty
    case failed(String)
    case loginRequired

    static func failure(_ error: Error) -> Self {
        if let error = error as? RedditClientError, error == .anonymousAccessBlocked {
            return .loginRequired
        }
        return .failed(error.localizedDescription)
    }
}

struct RedditLoginRequiredView: View {
    @Environment(AppDependencies.self) private var dependencies
    @State private var showingLogin = false

    var body: some View {
        ContentUnavailableView {
            Label("Reddit blocked this request", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text(RedditClientError.anonymousAccessBlocked.localizedDescription)
        } actions: {
            Button("Log in to Reddit") { showingLogin = true }
                .buttonStyle(.borderedProminent)
        }
        .sheet(isPresented: $showingLogin) {
            #if os(macOS)
            MacRedditLoginView(accounts: dependencies.accounts)
                .frame(minWidth: 720, minHeight: 620)
            #else
            RedditLoginView(accounts: dependencies.accounts)
            #endif
        }
    }
}

#Preview("Anonymous request blocked") {
    RedditLoginRequiredView()
        .environment(AppDependencies.preview())
        .frame(width: 600, height: 420)
}
