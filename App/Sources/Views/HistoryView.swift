import FreespanKit
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var undoing: Set<UUID> = []

    var body: some View {
        Group {
            if model.history.isEmpty {
                EmptyStateView(systemImage: "clock.arrow.circlepath", title: "No cleanups yet",
                               message: "Everything Freespan moves to the Trash is listed here, so you can put it back.")
            } else {
                List {
                    Section {
                        ForEach(model.history) { entry in
                            row(entry)
                        }
                    } header: {
                        HStack {
                            Text("\(model.history.count) action\(model.history.count == 1 ? "" : "s")")
                            Spacer()
                            Text("\(Format.bytes(freed)) moved to the Trash").monospacedDigit()
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task { await model.refreshHistory() }
    }

    private var freed: Int64 {
        model.history.filter { !$0.restored }.reduce(0) { $0 + $1.size }
    }

    private func row(_ entry: ActionLogEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.restored ? "arrow.uturn.backward.circle" : "trash.circle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(entry.restored ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text((entry.originalPath as NSString).lastPathComponent)
                    .font(.body.weight(.medium))
                    .strikethrough(entry.restored, color: .secondary)
                    .lineLimit(1)
                Text(Format.displayPath(PathUtil.parent(of: entry.originalPath), home: model.home))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                SizeText(bytes: entry.size)
                Text(entry.date.formatted(.relative(presentation: .named)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Group {
                if entry.restored {
                    Text("Restored").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                } else if undoing.contains(entry.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Undo") {
                        undoing.insert(entry.id)
                        Task {
                            await model.undo(entry)
                            undoing.remove(entry.id)
                        }
                    }
                }
            }
            .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Reveal in Finder") {
                model.revealInFinder(entry.restored ? entry.originalPath : entry.trashPath)
            }
        }
    }
}

#Preview("History") {
    HistoryView()
        .environment(AppModel.preview(selection: .history))
        .frame(width: 780, height: 420)
}
