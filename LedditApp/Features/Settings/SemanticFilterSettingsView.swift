import SwiftUI

@MainActor
struct SemanticFilterSettingsView: View {
    let intelligence: any IntelligenceService
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
    }

    private var statusText: String {
        if !isEnabled { return "Semantic filtering is paused." }
        if availability == .available { return "Ready to run on device." }
        return availability.userMessage
    }
}
