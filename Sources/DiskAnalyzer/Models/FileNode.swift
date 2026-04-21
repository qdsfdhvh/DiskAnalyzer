import Foundation

final class FileNode: Identifiable, Hashable {
    let id: UInt64
    let url: URL
    let name: String
    let isDirectory: Bool
    var size: Int64
    var children: [FileNode]?
    weak var parent: FileNode?

    // Monotonic counter shared across all scans in the process. Avoids the
    // per-node UUID/RNG overhead that shows up when building million-node trees.
    private static let idLock = NSLock()
    private static var nextID: UInt64 = 0

    private static func allocID() -> UInt64 {
        idLock.lock()
        nextID &+= 1
        let id = nextID
        idLock.unlock()
        return id
    }

    init(url: URL, name: String, isDirectory: Bool, size: Int64 = 0, children: [FileNode]? = nil) {
        self.id = Self.allocID()
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.children = children
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
