import AppKit
import ClipboardFormats
import Foundation
import HistoryCore
import UniformTypeIdentifiers

/// Explicit user export/open. History remains immutable; only declared local
/// references and known raster representations receive filesystem semantics.
enum HistoryOpenFailure: Error, Sendable, Equatable {
    case changed, unavailable, noApplication, temporaryLimit

    var message: String {
        switch self {
        case .changed: "This item changed or was removed. Open its menu again."
        case .unavailable: "The file is missing or cannot be opened."
        case .noApplication: "No application is available to open this file."
        case .temporaryLimit: "Temporary image storage is full. Save the image to a file instead."
        }
    }
}

struct HistoryOpenOption: Identifiable, Sendable {
    let request: HistoryRepresentationRequest
    let application: URL
    let applicationName: String
    let file: URL?
    let imageExtension: String?
    var id: String { "\(request.pasteboardItemIndex):\(request.typeIdentifier)" }
}

@MainActor
final class HistoryExternalOpener {
    private let history: any ClipboardHistory
    private let images: ExternalImageFiles
    private let applicationFor: @MainActor (URL?, String) -> URL?

    init(history: any ClipboardHistory, images: ExternalImageFiles = ExternalImageFiles(),
         applicationFor: @escaping @MainActor (URL?, String) -> URL? = { file, identifier in
             if let file { return NSWorkspace.shared.urlForApplication(toOpen: file) }
             guard let type = UTType(identifier) else { return nil }
             return NSWorkspace.shared.urlForApplication(toOpen: type)
         }) {
        self.history = history
        self.images = images
        self.applicationFor = applicationFor
    }

    static func supports(_ identifiers: [String]) -> Bool {
        identifiers.contains { isReference($0) || imageExtension(for: $0) != nil }
    }

    /// Metadata first; image bytes are read only after the explicit click.
    /// Menu choices are bounded independently of the retained payload size.
    func options(for item: HistoryItemReference) async throws -> [HistoryOpenOption] {
        try Task.checkCancellation()
        let metadata = try await history.representationMetadata(for: item)
        try Task.checkCancellation()
        let groups = Dictionary(grouping: metadata, by: \.pasteboardItemIndex)
        var result: [HistoryOpenOption] = []
        var firstFailure: HistoryOpenFailure?
        for index in groups.keys.sorted().prefix(32) {
            try Task.checkCancellation()
            do {
                let representations = groups[index] ?? []
                // A copied file's image representation is usually only its icon.
                // Prefer the actual file reference over any accompanying raster.
                let reference = representations.first { $0.typeIdentifier == ClipboardFormatIdentifier.fileURL.rawValue }
                    ?? representations.first { $0.typeIdentifier == ClipboardFormatIdentifier.url.rawValue }
                var file: URL?
                if let reference {
                    guard reference.byteCount <= 16 * 1_024 else { throw HistoryOpenFailure.unavailable }
                    let request = HistoryRepresentationRequest(item: item, basis: .effective,
                        typeIdentifier: reference.typeIdentifier, pasteboardItemIndex: index)
                    let representation = try await history.representation(request)
                    try Task.checkCancellation()
                    file = Self.localFileURL(representation.bytes)
                    if file == nil && reference.typeIdentifier == ClipboardFormatIdentifier.fileURL.rawValue {
                        throw HistoryOpenFailure.unavailable
                    }
                }
                let selected: HistoryRepresentationMetadata
                let suffix: String?
                let application: URL
                if file != nil, let reference {
                    selected = reference
                    suffix = nil
                    guard let resolved = applicationFor(file, selected.typeIdentifier) else {
                        throw HistoryOpenFailure.noApplication
                    }
                    application = resolved
                } else {
                    // One unavailable raster encoding must not hide another
                    // representation the installed default application can
                    // open. This selection still reads no image payloads.
                    var choice: (HistoryRepresentationMetadata, String, URL)?
                    var imageFailure: HistoryOpenFailure?
                    for image in representations {
                        try Task.checkCancellation()
                        guard let imageSuffix = Self.imageExtension(for: image.typeIdentifier) else { continue }
                        guard image.byteCount <= ExternalImageFiles.maximumFileBytes else {
                            if imageFailure == nil { imageFailure = .temporaryLimit }
                            continue
                        }
                        guard let resolved = applicationFor(nil, image.typeIdentifier) else {
                            if imageFailure == nil { imageFailure = .noApplication }
                            continue
                        }
                        choice = (image, imageSuffix, resolved)
                        break
                    }
                    guard let choice else {
                        if let imageFailure { throw imageFailure }
                        continue
                    }
                    selected = choice.0
                    suffix = choice.1
                    application = choice.2
                }
                let request = HistoryRepresentationRequest(item: item, basis: .effective,
                    typeIdentifier: selected.typeIdentifier, pasteboardItemIndex: index)
                result.append(HistoryOpenOption(request: request, application: application,
                    applicationName: application.deletingPathExtension().lastPathComponent,
                    file: file, imageExtension: suffix))
            } catch let failure as HistoryOpenFailure {
                if firstFailure == nil { firstFailure = failure }
            }
        }
        if result.isEmpty, let firstFailure { throw firstFailure }
        try Task.checkCancellation()
        return result
    }

    func open(_ option: HistoryOpenOption) async throws {
        do {
            // Re-read the exact representation/version at action time. A menu
            // kept open across a revision/removal cannot open obsolete bytes.
            let representation = try await history.representation(option.request)
            try Task.checkCancellation()
            let url: URL
            if let expected = option.file {
                guard Self.localFileURL(representation.bytes) == expected else { throw HistoryOpenFailure.changed }
                url = try await images.validateLocalFile(expected)
            } else if let suffix = option.imageExtension {
                url = try await images.export(representation.bytes, extension: suffix)
            } else {
                throw HistoryOpenFailure.unavailable
            }
            try Task.checkCancellation()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.addsToRecentItems = false
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: option.application,
                configuration: configuration)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as HistoryOpenFailure {
            throw failure
        } catch let failure as HistoryFailure {
            switch failure {
            case .notFound, .staleContent: throw HistoryOpenFailure.changed
            default: throw HistoryOpenFailure.unavailable
            }
        } catch {
            throw HistoryOpenFailure.unavailable
        }
    }

    nonisolated static func localFileURL(_ bytes: Data) -> URL? {
        guard bytes.count <= 16 * 1_024,
              let address = String(validating: bytes, as: UTF8.self),
              let url = URL(string: address, encodingInvalidCharacters: false),
              url.isFileURL,
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        return url
    }

    private static func isReference(_ type: String) -> Bool {
        type == ClipboardFormatIdentifier.fileURL.rawValue || type == ClipboardFormatIdentifier.url.rawValue
    }

    nonisolated static func imageExtension(for type: String) -> String? {
        switch type {
        case ClipboardFormatIdentifier.png.rawValue: "png"
        case ClipboardFormatIdentifier.jpeg.rawValue: "jpg"
        case ClipboardFormatIdentifier.tiff.rawValue: "tiff"
        case ClipboardFormatIdentifier.heic.rawValue: "heic"
        case ClipboardFormatIdentifier.heif.rawValue: "heif"
        case ClipboardFormatIdentifier.gif.rawValue: "gif"
        case ClipboardFormatIdentifier.bmp.rawValue: "bmp"
        case "org.webmproject.webp": "webp"
        default: nil
        }
    }
}

/// Serial, bounded disk work stays off MainActor. Exported files survive the
/// external app's open callback: that callback does not mean it finished
/// reading. A later session's first export removes only our UUID directories
/// older than 24 hours. Active session exports are never evicted for capacity.
actor ExternalImageFiles {
    static let maximumFileBytes = 64 * 1_024 * 1_024
    static let maximumSessionBytes = 256 * 1_024 * 1_024
    private let root: URL
    private let maximumFileBytes: Int
    private let maximumSessionBytes: Int
    private let cleanupDate: Date?
    private var sessionBytes = 0
    private var sessionCount = 0
    private var prepared = false

    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Clipy-Open-Images", isDirectory: true),
         maximumFileBytes: Int = ExternalImageFiles.maximumFileBytes,
         maximumSessionBytes: Int = ExternalImageFiles.maximumSessionBytes,
         cleanupDate: Date? = nil) {
        self.root = root
        self.maximumFileBytes = maximumFileBytes
        self.maximumSessionBytes = maximumSessionBytes
        self.cleanupDate = cleanupDate
    }

    func validateLocalFile(_ url: URL) throws -> URL {
        try Task.checkCancellation()
        let values: URLResourceValues
        do {
            // Resolve only for local-target validation. NSWorkspace still
            // receives the user's original path, including a valid symlink.
            values = try url.resolvingSymlinksInPath().resourceValues(
                forKeys: [.volumeIsLocalKey, .isRegularFileKey, .isDirectoryKey])
        } catch { throw HistoryOpenFailure.unavailable }
        guard values.volumeIsLocal == true,
              values.isRegularFile == true || values.isDirectory == true else { throw HistoryOpenFailure.unavailable }
        return url
    }

    func export(_ bytes: Data, extension suffix: String) throws -> URL {
        try Task.checkCancellation()
        guard !bytes.isEmpty, bytes.count <= maximumFileBytes,
              ["png", "jpg", "tiff", "heic", "heif", "gif", "bmp", "webp"].contains(suffix) else { throw HistoryOpenFailure.temporaryLimit }
        let manager = FileManager.default
        do {
            if !prepared {
                try manager.createDirectory(at: root, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let attributes = try manager.attributesOfItem(atPath: root.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw HistoryOpenFailure.unavailable }
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
                cleanupExpired(now: cleanupDate ?? Date())
                prepared = true
            }
            guard bytes.count <= maximumSessionBytes - sessionBytes, sessionCount < 128 else {
                throw HistoryOpenFailure.temporaryLimit
            }
            let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let destination = directory.appendingPathComponent("Clipboard." + suffix)
            do {
                try Task.checkCancellation()
                try bytes.write(to: destination, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                sessionBytes += bytes.count
                sessionCount += 1
                return destination
            } catch {
                try? manager.removeItem(at: directory)
                throw error
            }
        } catch is CancellationError { throw CancellationError() }
        catch let failure as HistoryOpenFailure { throw failure }
        catch { throw HistoryOpenFailure.unavailable }
    }

    private func cleanupExpired(now: Date) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for entry in entries {
            guard UUID(uuidString: entry.lastPathComponent) != nil,
                  let values = try? entry.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            if let created = values.creationDate, now.timeIntervalSince(created) > 24 * 60 * 60 {
                do { try manager.removeItem(at: entry); continue } catch { }
            }
            // Include unexpired previous-session copies in admission. Restarting
            // the app cannot multiply the retained temporary-byte allowance.
            sessionCount += 1
            guard let files = try? manager.contentsOfDirectory(at: entry,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
                sessionBytes = maximumSessionBytes
                continue
            }
            for file in files {
                guard let fileValues = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      fileValues.isRegularFile == true, let size = fileValues.fileSize else { continue }
                sessionBytes += min(max(0, size), maximumSessionBytes - sessionBytes)
            }
        }
    }
}
