import AppKit
import LotcKit
import SwiftUI

/// The sidebar's way to the Auto-approve page, with how many requests it approved in the last hour.
struct AutoApproveSidebarRow: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var approvals: AutoApprovals

    private var status: String {
        guard approvals.settings.isOn else { return "Off: every prompt comes to you" }
        let on = AutoApproveRule.allCases.filter(approvals.settings.isOn).count
        return "On: \(on) of \(AutoApproveRule.allCases.count) rules"
    }

    var body: some View {
        let showing = model.pane == .autoApprove
        Button { model.showAutoApprove() } label: {
            HStack(spacing: 10) {
                Image(systemName: approvals.settings.isOn ? "checkmark.shield.fill" : "shield")
                    .foregroundStyle(approvals.settings.isOn ? Color.accentColor : .secondary)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-approve")
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let count = approvals.approvedCount(since: context.date.addingTimeInterval(-3600))
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.1)))
                            .help("\(count) approved in the last hour")
                            .accessibilityLabel("\(count) approved in the last hour")
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(showing ? Color.accentColor.opacity(0.25) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("The rules that approve safe permission requests for you, and what they approved")
        .accessibilityAddTraits(showing ? .isSelected : [])
    }
}

/// The master switch, each rule, the excluded directories and the log of what the rules approved.
struct AutoApprovePage: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var approvals: AutoApprovals
    @State private var expanded: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    master
                    rules
                    excluded
                    log
                }
                .readingColumn()
                .padding(.vertical, 16)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if !model.sidebarVisible { SidebarButton(model: model) }
            Button(action: model.showChat) { Label("Overseer", systemImage: "chevron.left") }
                .help("Back to the chat (⌘L or Esc)")
            Spacer()
            Text("Auto-approve").font(.headline).accessibilityAddTraits(.isHeader)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: MainView.headerHeight)
    }

    private var master: some View {
        SwitchRow(title: "Approve safe requests by rule",
                  detail: "A rule can only say yes. Anything no rule recognises comes to the permission window as before.",
                  isOn: Binding(get: { approvals.settings.isOn }, set: { approvals.setOn($0) }), headline: true)
    }

    private var rules: some View {
        section("Rules") {
            if !approvals.settings.isOn {
                Text("None of these applies while the switch above is off.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(AutoApproveRule.allCases, id: \.self) { rule in
                SwitchRow(title: rule.title, detail: rule.summary,
                          isOn: Binding(get: { approvals.settings.isOn(rule) }, set: { approvals.set(rule, on: $0) }))
                    .opacity(approvals.settings.isOn ? 1 : 0.6)
            }
        }
    }

    private var excluded: some View {
        section("Excluded directories") {
            Text("A session working in one of these is never auto-approved, never summarised and left out of the overseer's briefing. The sidebar shows it by title only, marked private.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if approvals.settings.excludedDirectories.isEmpty {
                Text("None.").font(.callout)
            }
            ForEach(approvals.settings.excludedDirectories, id: \.self) { entry in
                HStack {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    Text(entry).font(.callout.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button("Remove") { approvals.include(entry) }
                        .accessibilityLabel("Stop excluding \(entry)")
                }
            }
            Button("Add a directory…", action: chooseDirectories)
        }
    }

    private var log: some View {
        section("Approved", note: "Newest first. The last \(ApprovalLog.cap) are kept.") {
            if approvals.log.isEmpty {
                Text("Nothing approved yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(approvals.log.reversed()) { entry in
                        ApprovalRow(entry: entry, approvals: approvals,
                                    expanded: Binding(get: { expanded == entry.id },
                                                      set: { expanded = $0 ? entry.id : nil }))
                        Divider()
                    }
                }
            }
        }
    }

    private func section(_ title: String, note: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased()).font(.caption).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                Spacer()
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
    }

    private func chooseDirectories() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = "Exclude"
        panel.message = "Sessions working in these directories stay private and are never auto-approved."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { approvals.exclude(url.path) }
    }
}

/// A setting in words on the left, its switch lined up on the right.
private struct SwitchRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var headline = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(headline ? .title3.weight(.semibold) : .body)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
    }
}

/// One approval: when, what and by which rule. A click shows the full text and a way to switch the rule off.
private struct ApprovalRow: View {
    let entry: ApprovalLogEntry
    @ObservedObject var approvals: AutoApprovals
    @Binding var expanded: Bool

    private var rule: AutoApproveRule? { AutoApproveRule(rawValue: entry.rule) }
    private var ruleIsOn: Bool { rule.map(approvals.settings.isOn) == true }

    private var time: String {
        Calendar.current.isDateInToday(entry.at)
            ? entry.at.formatted(date: .omitted, time: .shortened)
            : entry.at.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SessionText.oneLine(entry.summary)).font(.callout.monospaced())
                            .lineLimit(1).truncationMode(.middle)
                        Text("\(entry.session) · \(entry.tool) · \(entry.ruleTitle)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(expanded ? "Hides the full text" : "Shows the full text")
            if expanded {
                Text(entry.summary)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                HStack {
                    Text(SessionText.shortPath(entry.cwd)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    stopButton
                }
            }
        }
        .padding(.vertical, 8)
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.summary, forType: .string)
            }
            if let rule, ruleIsOn { Button("Stop approving by \(rule.title)") { approvals.set(rule, on: false) } }
        }
    }

    @ViewBuilder private var stopButton: some View {
        if let rule, ruleIsOn {
            Button("Stop approving this rule") { approvals.set(rule, on: false) }
                .help("Switches \(rule.title) off. Its requests come to the permission window again.")
        } else {
            Text("\(entry.ruleTitle) is off").font(.caption).foregroundStyle(.secondary)
        }
    }
}
