import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum AppIconChoice: String, CaseIterable, Identifiable {
    case liquidGlass, pearlPlush, frostedPink, original

    static let preferenceKey = "appearance.appIcon"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .liquidGlass: "Liquid Glass"
        case .pearlPlush: "Pearl Plush (A)"
        case .frostedPink: "Frosted Pink (B)"
        case .original: "Pearl Plush"
        }
    }
    // UIKit uses nil for the primary iOS icon.
    var alternateName: String? {
        switch self {
        case .liquidGlass: "Octonaut-Pearl-Blue"
        case .pearlPlush: "Octonaut-Pearl-Plush"
        case .frostedPink: "Octonaut-Frosted-Pink"
        case .original: nil
        }
    }

    static func fromAlternateName(_ name: String?) -> Self {
        allCases.first { $0.alternateName == name } ?? .original
    }

    var previewName: String? {
        switch self {
        case .liquidGlass: "PearlBluePreview"
        case .pearlPlush: "PearlPlushPreview"
        case .frostedPink: "FrostedPinkPreview"
        case .original: nil
        }
    }

    #if os(macOS)
    @MainActor
    static func applyDockIcon(_ rawValue: String) {
        let choice = Self(rawValue: rawValue) ?? .original
        NSApplication.shared.applicationIconImage = choice.previewName.flatMap { NSImage(named: $0) }
    }
    #endif
}

@MainActor
struct AppIconPicker: View {
    @AppStorage(AppIconChoice.preferenceKey) private var savedChoice = AppIconChoice.original.rawValue
    #if os(macOS)
    @State private var currentChoice = AppIconChoice.original
    #else
    @State private var currentChoice = AppIconChoice.original
    #endif
    @State private var isChanging = false
    @State private var errorMessage: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section("App icon") {
            Picker("Icon", selection: Binding(get: { currentChoice }, set: changeIcon)) {
                ForEach(AppIconChoice.allCases.filter { $0 != .pearlPlush }) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .disabled(isChanging || !supportsChanges)
            #if os(macOS)
            Text("Changes the Dock icon while Octonaut is running. Finder uses the Pearl Plush icon.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            #endif
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
        }
        .onAppear(perform: refreshChoice)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshChoice() }
        }
        .onChange(of: savedChoice) { _, _ in refreshChoice() }
    }

    private var supportsChanges: Bool {
        #if os(macOS)
        true
        #else
        UIApplication.shared.supportsAlternateIcons
        #endif
    }

    private func refreshChoice() {
        #if os(macOS)
        currentChoice = AppIconChoice(rawValue: savedChoice) ?? .original
        #else
        currentChoice = AppIconChoice.fromAlternateName(UIApplication.shared.alternateIconName)
        #endif
    }

    private func changeIcon(_ choice: AppIconChoice) {
        guard choice != currentChoice, !isChanging else { return }
        errorMessage = nil
        #if os(macOS)
        AppIconChoice.applyDockIcon(choice.rawValue)
        savedChoice = choice.rawValue
        currentChoice = choice
        #else
        isChanging = true
        Task { @MainActor in
            defer { isChanging = false }
            do {
                try await UIApplication.shared.setAlternateIconName(choice.alternateName)
                refreshChoice()
            } catch {
                refreshChoice()
                errorMessage = "Could not change the app icon. \(error.localizedDescription)"
            }
        }
        #endif
    }
}
