import SwiftUI

@MainActor
struct HelpGuideView: View {
    @State private var model: HelpAssistantModel

    init(intelligence: any IntelligenceService) {
        _model = State(initialValue: HelpAssistantModel(intelligence: intelligence))
    }

    var body: some View {
        @Bindable var model = model
        return List {
            if model.isAnswering {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Preparing an answer on device…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let answer = model.answer {
                Section("Answer") {
                    Text(answer.answer)
                    if !answer.citedSectionIDs.isEmpty {
                        Text("Based on: " + answer.citedSectionIDs.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Help") {
                ForEach(model.results) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.section.title)
                            .font(.headline)
                        Text(result.section.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    .padding(.vertical, 3)
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $model.query, prompt: "Search the guide")
        .onSubmit(of: .search) { model.search() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Ask on device") {
                    Task { await model.answerQuestion() }
                }
                .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isAnswering)
            }
        }
    }
}
