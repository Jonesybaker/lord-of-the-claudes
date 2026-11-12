import SwiftUI

/// What became of the last prompt sent from a field in the panel, shown under that field.
struct SendNote: Equatable {
    enum Outcome { case sending, sent, failed }
    let outcome: Outcome
    let text: String
}

struct SendNoteView: View {
    let note: SendNote

    var body: some View {
        HStack(spacing: 5) {
            switch note.outcome {
            case .sending: ProgressView().controlSize(.mini)
            case .sent: Image(systemName: "checkmark").foregroundStyle(.secondary)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.waiting)
            }
            Text(note.text).foregroundStyle(note.outcome == .failed ? .primary : .secondary)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}
