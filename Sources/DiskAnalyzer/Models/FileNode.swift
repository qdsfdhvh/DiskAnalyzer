import Foundation

final class FileNode: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    var size: Int64
    var children: [FileNode]?
    weak var parent: FileNode?

    init(url: URL, name: String, isDirectory: Bool, size: Int64 = 0, children: [FileNode]? = nil) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.children = children
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
