/// Source-icon retention through the existing synchronous provider seam:
/// pure row reads, negative values, FIFO capacity, and provider reentry.
import CoreGraphics
import Foundation
import PresentationUI
import Testing

@MainActor
struct SourceIconStoreTests {
    @Test
    func rowReadsDoNotLoadAndRepeatedMissingIconsAreRetained() {
        let calls = IconProviderCalls()
        let store = SourceIconStore(provider: SourceIconProvider { bundleID in
            calls.bundleIDs.append(bundleID)
            return nil
        })
        #expect(store.cachedIcon(forBundleID: "com.example.Missing") == nil)
        #expect(calls.bundleIDs.isEmpty)
        #expect(store.icon(forBundleID: "com.example.Missing") == nil)
        #expect(store.icon(forBundleID: "com.example.Missing") == nil)
        #expect(store.cachedIcon(forBundleID: "com.example.Missing") == nil)
        #expect(calls.bundleIDs == ["com.example.Missing"])
    }

    @Test
    func negativeEntriesUseTheSameFIFO64BoundAndHitsDoNotPromoteThem() {
        let calls = IconProviderCalls()
        let store = SourceIconStore(provider: SourceIconProvider { bundleID in
            calls.bundleIDs.append(bundleID)
            return nil
        })
        for index in 0..<64 {
            store.icon(forBundleID: "com.example.App\(index)")
        }
        #expect(calls.bundleIDs.count == 64)
        store.icon(forBundleID: "com.example.App0")
        #expect(calls.bundleIDs.count == 64)
        store.icon(forBundleID: "com.example.App64")
        store.icon(forBundleID: "com.example.App1")
        #expect(calls.bundleIDs.count == 65)
        store.icon(forBundleID: "com.example.App0")
        #expect(calls.bundleIDs.count == 66)
        #expect(calls.bundleIDs.filter { $0 == "com.example.App0" }.count == 2)
    }

    @Test
    func sameBundleReentryLoadsOnceAndPublishesTheOuterResult() throws {
        let calls = IconProviderCalls()
        calls.image = try image()
        let store = SourceIconStore(provider: SourceIconProvider { bundleID in
            calls.bundleIDs.append(bundleID)
            if calls.bundleIDs.count == 1 {
                calls.reentrantImage = calls.store?.icon(forBundleID: bundleID)
            }
            return calls.image
        })
        calls.store = store
        let resolved = store.icon(forBundleID: "com.example.Reentrant")
        #expect(calls.bundleIDs == ["com.example.Reentrant"])
        #expect(calls.reentrantImage == nil)
        #expect(resolved === calls.image)
        #expect(store.cachedIcon(forBundleID: "com.example.Reentrant") === calls.image)
        #expect(store.icon(forBundleID: "com.example.Reentrant") === calls.image)
        #expect(calls.bundleIDs.count == 1)
    }

    @Test
    func providerCompletionCannotResurrectAnEntryEvictedByNestedLoads() throws {
        let calls = IconProviderCalls()
        calls.image = try image()
        let outer = "com.example.Outer"
        let store = SourceIconStore(provider: SourceIconProvider { bundleID in
            calls.bundleIDs.append(bundleID)
            if bundleID == outer, calls.bundleIDs.count == 1 {
                for index in 0..<64 {
                    calls.store?.icon(forBundleID: "com.example.Nested\(index)")
                }
            }
            return calls.image
        })
        calls.store = store
        #expect(store.icon(forBundleID: outer) === calls.image)
        #expect(store.cachedIcon(forBundleID: outer) == nil)
        #expect(calls.bundleIDs.count == 65)
        // All 64 nested entries remain retained; the completed outer call
        // did not silently create a 65th entry or evict their first icon.
        for index in 0..<64 {
            #expect(store.icon(forBundleID: "com.example.Nested\(index)") === calls.image)
        }
        #expect(calls.bundleIDs.count == 65)
        store.icon(forBundleID: outer)
        #expect(calls.bundleIDs.count == 66)
        #expect(store.cachedIcon(forBundleID: "com.example.Nested0") == nil)
    }

    @Test
    func evictedResolutionCannotOverwriteANewerResolutionForTheSameBundle() throws {
        let calls = IconProviderCalls()
        calls.image = try image()
        calls.replacementImage = try image(width: 2)
        let outer = "com.example.ReResolved"
        let store = SourceIconStore(provider: SourceIconProvider { bundleID in
            calls.bundleIDs.append(bundleID)
            if bundleID == outer {
                if calls.bundleIDs.count == 1 {
                    for index in 0..<64 {
                        calls.store?.icon(forBundleID: "com.example.Nested\(index)")
                    }
                    // The first resolution was evicted; a new resolution
                    // now retains a different icon under the same key.
                    calls.reentrantImage = calls.store?.icon(forBundleID: outer)
                    return calls.image
                }
                return calls.replacementImage
            }
            return calls.image
        })
        calls.store = store

        #expect(store.icon(forBundleID: outer) === calls.image)
        #expect(calls.reentrantImage === calls.replacementImage)
        #expect(store.cachedIcon(forBundleID: outer) === calls.replacementImage)
        #expect(store.icon(forBundleID: outer) === calls.replacementImage)
        #expect(calls.bundleIDs.count == 66)
        #expect(store.cachedIcon(forBundleID: "com.example.Nested0") == nil)
        #expect(store.cachedIcon(forBundleID: "com.example.Nested1") === calls.image)
    }

    private func image(width: Int = 1) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: 1, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }
}

@MainActor
private final class IconProviderCalls {
    var bundleIDs: [String] = []
    var image: CGImage?
    var replacementImage: CGImage?
    var reentrantImage: CGImage?
    weak var store: SourceIconStore?
}
