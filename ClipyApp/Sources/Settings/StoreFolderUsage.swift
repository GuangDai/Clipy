/// Maintenance reads the folder of the configured store, including hidden
/// SwiftData files. It does not infer a private database-family layout.
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
        var directories = [root]
        var total = 0
        while let directory = directories.popLast() {
            try Task.checkCancellation()
            let children = try manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys), options: []
            )
            for child in children {
                try Task.checkCancellation()
                let values = try child.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    directories.append(child)
                } else if values.isRegularFile == true {
                    guard let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    total += allocated
                }
            }
        }
        return total
    }
}
