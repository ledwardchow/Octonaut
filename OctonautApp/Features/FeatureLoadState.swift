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

struct RedditLoginWelcomeView: View {
    let anonymousRequestsBlocked: Bool
    let onSignIn: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var showingAnonymousBlockAlert = false
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize = 112
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 30

    init(anonymousRequestsBlocked: Bool = false, onSignIn: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.anonymousRequestsBlocked = anonymousRequestsBlocked
        self.onSignIn = onSignIn
        self.onDismiss = onDismiss
    }

    private var actionColor: Color {
        colorScheme == .dark
            ? Color(red: 1, green: 156.0 / 255, blue: 101.0 / 255)
            : Color(red: 185.0 / 255, green: 67.0 / 255, blue: 10.0 / 255)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)

                    VStack(spacing: 0) {
                        Image("RedditLoginWelcomeIcon")
                            .resizable()
                            .interpolation(.high)
                            .frame(width: iconSize, height: iconSize)
                            .clipShape(RoundedRectangle(cornerRadius: iconSize / 4))
                            .accessibilityHidden(true)
                            .padding(.bottom, 29)

                        Text("Octonaut")
                            .font(.caption.weight(.semibold))
                            .tracking(1.3)
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 12)

                        Text("Make yourself\nat home.")
                            .font(.system(size: titleSize, weight: .bold))
                            .tracking(-0.9)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 17)

                        Text("Sign in with your Reddit account to see your communities, saved posts and conversations.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 285)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                    Spacer(minLength: 36)

                    Button(action: onSignIn) {
                        HStack(spacing: 8) {
                            Text("Sign in to Reddit")
                            Image(systemName: "arrow.right")
                                .accessibilityHidden(true)
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .foregroundStyle(colorScheme == .dark ? Color(red: 40.0 / 255, green: 17.0 / 255, blue: 0) : .white)
                        .background(actionColor, in: RoundedRectangle(cornerRadius: 17))
                    }
                    .buttonStyle(.plain)

                    Button("Not now") {
                        if anonymousRequestsBlocked {
                            showingAnonymousBlockAlert = true
                        } else {
                            onDismiss()
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(actionColor)
                    .frame(maxWidth: .infinity, minHeight: 47)
                    .buttonStyle(.plain)

                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "lock.fill")
                            .accessibilityHidden(true)
                        Text("You sign in on Reddit.\nYour session stays in this device’s Keychain.")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 15)
                    .padding(.bottom, 25)
                }
                .padding(.horizontal, 25)
                .frame(maxWidth: 390)
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .background(.background)
        .alert("Sign in to use Octonaut", isPresented: $showingAnonymousBlockAlert) {
            Button("Sign in to Reddit", action: onSignIn)
            Button("Continue without signing in", action: onDismiss)
        } message: {
            Text("You're being automatically shown a login prompt because Reddit is blocking signed-out requests. Octonaut can't load feeds or posts unless you sign in.")
        }
    }
}

#Preview("Reddit login welcome") {
    RedditLoginWelcomeView(onSignIn: {}, onDismiss: {})
}

struct RedditLoginRequiredView: View {
    @Environment(AppDependencies.self) private var dependencies
    @State private var showingLogin = false
    @State private var didPresentLoginAutomatically = false

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
            MacRedditLoginView(accounts: dependencies.accounts, anonymousRequestsBlocked: true)
                .frame(minWidth: 720, minHeight: 620)
            #else
            RedditLoginView(accounts: dependencies.accounts, anonymousRequestsBlocked: true)
            #endif
        }
        .onAppear {
            guard !didPresentLoginAutomatically else { return }
            didPresentLoginAutomatically = true
            showingLogin = true
        }
    }
}

#Preview("Anonymous request blocked") {
    RedditLoginRequiredView()
        .environment(AppDependencies.preview())
        .frame(width: 600, height: 420)
}

/// The login page opens only after the user chooses Log In.
private struct LoginRequirementModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(AppDependencies.self) private var dependencies
    @State private var showingLogin = false

    func body(content: Content) -> some View {
        content
            .alert("Login Required", isPresented: $isPresented) {
                Button("Cancel", role: .cancel) {}
                Button("Log In") { showingLogin = true }
            } message: {
                Text("You need to be logged in to use this option.")
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

extension View {
    func loginRequiredModal(isPresented: Binding<Bool>) -> some View {
        modifier(LoginRequirementModifier(isPresented: isPresented))
    }
}
