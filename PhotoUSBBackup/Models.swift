import Foundation

struct PhotoTreeNode: Identifiable, Hashable {
    let id: String
    let title: String
    let kind: Kind
    let localIdentifier: String
    let children: [PhotoTreeNode]

    enum Kind: String, Hashable {
        case folder
        case album
    }
}

struct CopyFailure: Identifiable {
    let id = UUID()
    let path: String
    let reason: String
}

struct CopyStats {
    var processedAssets = 0
    var totalAssets = 0
    var copiedFiles = 0
    var skippedFiles = 0
    var failedFiles = 0
}
