import SwiftUI

struct AlbumPickerView: View {
    @EnvironmentObject private var manager: AlbumCopyManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(manager.photoTree) { node in
                    NodeView(node: node) {
                        manager.selectSource($0)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Choose Album / Folder")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct NodeView: View {
    let node: PhotoTreeNode
    let onSelect: (PhotoTreeNode) -> Void

    var body: some View {
        if node.children.isEmpty {
            Button {
                onSelect(node)
            } label: {
                Label(node.title, systemImage: node.kind == .folder ? "folder" : "photo.on.rectangle")
            }
        } else {
            DisclosureGroup {
                Button("Use this folder") { onSelect(node) }
                    .font(.subheadline)
                ForEach(node.children) { child in
                    NodeView(node: child, onSelect: onSelect)
                }
            } label: {
                Label(node.title, systemImage: node.kind == .folder ? "folder.fill" : "photo.on.rectangle")
            }
        }
    }
}
