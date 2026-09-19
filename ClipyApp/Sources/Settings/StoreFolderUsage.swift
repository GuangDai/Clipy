/// Maintenance reads the folder of the configured store, including hidden
/// files. It does not infer a private database-family layout.
import Foundation

actor StoreFolderUsage {
    private let directoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// An on-demand estimate of allocated regular-file bytes, not logical
    /// content or uniquely owned APFS blocks. A fresh traversal avoids cached
    /// URL resource values between refreshes. Files may change during a read.
    func allocatedBytes() throws -> Int {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: directoryURL.path, isDirectory: true)
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnknown)
        }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        ]
        // Stream entries rather than retaining every URL in a blob directory.
        // A failed subtree makes the estimate unavailable, never a misleading
        // successful partial total. Enumeration is synchronous on this actor.
        var enumerationFailure: (any Error)?
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, error in
                enumerationFailure = error
                return false
            }
        ) else { throw CocoaError(.fileReadUnknown) }
        var total = 0
        while let child = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: keys)
            // URL enumeration already excludes symlink descendants. Its
            // skipDescendants operation is for a returned directory, not
            // a link; simply exclude the link's own allocation here.
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                guard let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize else {
                    throw CocoaError(.fileReadUnknown)
                }
                total += allocated
            }
        }
        if let enumerationFailure { throw enumerationFailure }
        try Task.checkCancellation()
        return total
    }
}
