import FreespanKit
import SwiftUI

/// Shared context menu for anything that maps to a path: map slices, map rows, group rows, basket rows.
struct ItemContextMenu: View {
    @Environment(AppModel.self) private var model
    let path: String
    var finding: Finding?
    var showInMap = false

    private var node: FileNode? { model.node(at: path) }
    private var name: String { finding?.name ?? node?.name ?? (path as NSString).lastPathComponent }
    private var size: Int64 { finding?.size ?? node?.size ?? 0 }
    private var isAggregate: Bool { node?.kind == .smallFiles }

    private var basketCandidate: Finding? {
        finding ?? node.flatMap { model.cleanableFinding(for: $0) }
    }

    var body: some View {
        Button("Reveal in Finder") { model.revealInFinder(path) }
        Button("Quick Look") { model.quickLook(path) }
            .disabled(isAggregate)
        if showInMap {
            Button("Show in Disk Map") { model.showInMap(path) }
        }
        Divider()
        if model.isInBasket(path) {
            Button("Remove from Basket") { model.removeFromBasket(path) }
                .disabled(model.basket[path] == nil)
        } else {
            Button("Add to Basket") {
                if let basketCandidate { model.addToBasket(basketCandidate) }
            }
            .disabled(isAggregate || basketCandidate.map { !model.canAddToBasket($0) } ?? true)
        }
        // macOS internals and app data are never sent to the assistant, so there's nothing to ask.
        if !isAggregate, model.canAskAssistant(about: path) {
            Divider()
            Button("Explain") { model.explain(path: path, name: name, size: size) }
                .disabled(!model.assistantReady)
            if model.mode == .advanced {
                Button("Get a Second Opinion") {
                    if let node { model.secondOpinion(on: node) }
                }
                .disabled(node == nil || !model.assistantReady)
            }
        }
    }
}
