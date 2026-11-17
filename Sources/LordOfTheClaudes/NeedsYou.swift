import SwiftUI

/// "What needs me": every running session waiting for the user, across all windows, longest wait first.
/// Worked out from the rows alone, with no model call.
enum NeedsYou {
    /// Waiting means it has stopped and either finished work the user has not seen, or its digest
    /// says it is blocked on them (seen but not answered).
    static func ranked(_ rows: [Row]) -> [Row] {
        rows.filter { $0.isLive && $0.status != "busy" && ($0.needsYou || $0.digest?.blockedOn != nil) }
            .sorted { (waitingSince($0), $0.title) < (waitingSince($1), $1.title) }
    }

    /// When it stopped, which is when it started waiting.
    static func waitingSince(_ row: Row) -> Date { row.statusSince ?? row.lastInteraction }

    /// What it waits for: the digest's blocked-on line, else where it got to, else what it was last asked.
    static func reason(_ row: Row) -> String {
        if let blockedOn = row.digest?.blockedOn?.trimmedNonEmpty { return blockedOn }
        if let state = row.digest?.state.trimmedNonEmpty { return state }
        if let prompt = row.prompts.last?.text.split(whereSeparator: \.isNewline).first {
            return "Finished. You last asked: \(prompt)"
        }
        return "Finished, and has not been prompted from here"
    }
}

/// The sessions waiting for you, longest first. A click shows one's detail; its arrow goes to its tab.
struct NeedsYouList: View {
    let rows: [Row]
    let places: [SessionPlace]
    let show: (Row) -> Void
    let goTo: (Row) -> Void

    var body: some View {
        let waiting = NeedsYou.ranked(rows)
        VStack(alignment: .leading, spacing: 4) {
            Text(waiting.isEmpty ? "WAITING FOR YOU" : "WAITING FOR YOU, LONGEST FIRST")
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if waiting.isEmpty {
                let working = rows.filter { $0.status == "busy" }.count
                Text("Nothing is waiting for you." + (working > 0 ? " \(working) working." : ""))
                    .foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(waiting) { row in item(row) }
        }
    }

    private func item(_ row: Row) -> some View {
        let spot = places.first { $0.rowId == row.id }?.spot
        let age = shortAge(NeedsYou.waitingSince(row))
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { show(row) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "bell.fill").font(.caption).foregroundStyle(Color.waiting)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.title).lineLimit(1)
                            if let spot { Text(spot).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Text(NeedsYou.reason(row)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 6)
                    Text(age).font(.caption.monospacedDigit()).foregroundStyle(Color.waiting)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show its detail")
            .accessibilityLabel("\(row.title), \(spot ?? ""), waiting \(age). \(NeedsYou.reason(row))")
            Button { goTo(row) } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless)
                .help("Go to its tab")
                .accessibilityLabel("Go to the tab of \(row.title)")
        }
    }
}
