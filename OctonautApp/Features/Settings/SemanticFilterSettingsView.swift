import SwiftUI

@MainActor
struct SemanticFilterSettingsView: View {
    let intelligence: any IntelligenceService
    @Environment(AppDependencies.self) private var dependencies
    @AppStorage("filters.semantic.enabled") private var isEnabled = false
    @AppStorage("filters.semantic.instruction") private var instruction = "Hide posts that are mainly promotional."
    @AppStorage("filters.blockedCommunities") private var blockedCommunities = ""
    @AppStorage("filters.keywordTerms") private var keywordTerms = ""
    @State private var availability: IntelligenceAvailability = .unsupported

    var body: some View {
        Group {
            Text("Semantic filter")
                .font(.headline)
            TextField("Blocked communities (comma-separated)", text: $blockedCommunities)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Keyword terms (comma-separated)", text: $keywordTerms)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("Use on-device semantic rules", isOn: $isEnabled)
            TextField("What should be hidden?", text: $instruction, axis: .vertical)
                .lineLimit(2...5)
                .disabled(!isEnabled)
            Label(statusText, systemImage: isEnabled && availability == .available ? "checkmark.circle" : "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Rules are evaluated in small batches on this device. If the model is unavailable or returns an invalid result, posts stay visible.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Clear semantic rule") {
                instruction = ""
                isEnabled = false
            }
            .disabled(instruction.isEmpty && !isEnabled)
        }
        .task {
            availability = await intelligence.availability
        }
        // These are applied when a page is fetched, so a cached feed has to
        // be dropped for a change to them to take effect.
        .onChange(of: blockedCommunities) { _, _ in dependencies.settings.noteFilterChanged() }
        .onChange(of: keywordTerms) { _, _ in dependencies.settings.noteFilterChanged() }
        .onChange(of: isEnabled) { _, _ in dependencies.settings.noteFilterChanged() }
        .onChange(of: instruction) { _, _ in dependencies.settings.noteFilterChanged() }
    }

    private var statusText: String {
        if !isEnabled { return "Semantic filtering is paused." }
        if availability == .available { return "Ready to run on device." }
        return availability.userMessage
    }
}
