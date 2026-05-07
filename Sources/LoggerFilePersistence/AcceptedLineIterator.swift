import Foundation

/// Internal byte-stable iterator over accepted envelope lines.
///
/// Yields accepted lines in accepted ordering. Trailing partial bytes are
/// excluded; interior corruption hard-stops iteration. The read path is
/// non-destructive.
internal enum AcceptedLineIterator {
    /// Returns a pull-based ``AsyncSequence`` over the configured
    /// segment layout. No file I/O happens until the first `next()`
    /// call; consumer cancellation halts further reads.
    static func acceptedLines(
        configuration: FileLogStore.Configuration
    ) -> AcceptedLineSequence {
        AcceptedLineSequence(configuration: configuration)
    }
}

/// Pull-based async sequence over accepted envelope lines.
///
/// Each `for await` step calls the iterator's `next()` once; the
/// iterator reads chunks lazily and never queues unconsumed lines.
internal struct AcceptedLineSequence: AsyncSequence {
    typealias Element = Data

    private let configuration: FileLogStore.Configuration

    fileprivate init(configuration: FileLogStore.Configuration) {
        self.configuration = configuration
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(configuration: configuration)
    }

    /// Class-based async iterator. Holds the configured root as a
    /// `SegmentRoot` (an `O_NOFOLLOW` directory descriptor) for the
    /// lifetime of iteration so segment opens go through
    /// `openat(rootFD, name, O_NOFOLLOW)` and a path-component swap
    /// after discovery cannot redirect reads to a symlink target.
    /// Owns the open `FileHandle` for the current segment so deinit
    /// closes it when the consumer drops the iterator (e.g. on early
    /// termination or task cancellation).
    internal final class AsyncIterator: AsyncIteratorProtocol {
        typealias Element = Data

        private let configuration: FileLogStore.Configuration
        private var root: SegmentRoot?
        private var segments: [URL]?
        private var nextSegmentIndex: Int
        private var currentSegmentURL: URL?
        private var currentHandle: FileHandle?
        private var currentScanner: RecoverablePrefixScanner.Iterator?
        private var terminated: Bool
        private var aggregateChunkReads: Int
        /// Iterator-local deferred-close queue for per-segment
        /// read handles. Mirrors the actor's
        /// `pendingCloseHandles` discipline for non-actor-owned
        /// reader paths: a transient `close(2)` failure is
        /// retained and retried at the next iterator boundary
        /// (advance, terminate, deinit) instead of being
        /// silently dropped.
        private var pendingCloseHandles: [FileHandle]

        /// Total non-empty chunk reads observed across every
        /// segment's scanner. Used by tests to verify pull-based
        /// streaming behavior.
        internal var chunkReadCountForTesting: Int {
            aggregateChunkReads + (currentScanner?.chunkReadCountForTesting ?? 0)
        }

        /// TEST-ONLY release observer for cleanup assertions.
        internal var _releaseObserverForTesting: (() -> Void)? // swiftlint:disable:this identifier_name

        /// TEST-ONLY hook fired after segment discovery completes,
        /// before the first segment open. Lets tests deterministically
        /// race a path-component swap against `openat`. Throwing is
        /// preserved so a setup failure surfaces as a thrown error
        /// from `next()` instead of being silently swallowed.
        internal var _onSegmentsDiscoveredForTesting: (() throws -> Void)? // swiftlint:disable:this identifier_name

        fileprivate init(configuration: FileLogStore.Configuration) {
            self.configuration = configuration
            root = nil
            segments = nil
            nextSegmentIndex = 0
            currentSegmentURL = nil
            currentHandle = nil
            currentScanner = nil
            terminated = false
            aggregateChunkReads = 0
            pendingCloseHandles = []
        }

        deinit {
            releaseCurrentSegment()
            drainPendingCloseHandles()
            root?.close()
        }

        /// Pulls the next accepted line's bytes. Returns `nil` when
        /// every segment has been fully scanned, or promptly when
        /// the enclosing `Task` is cancelled. Throws on I/O failure
        /// or interior corruption (terminal hard-stop).
        func next() async throws -> Data? {
            if terminated { return nil }
            if segments == nil {
                if Task.isCancelled {
                    terminate()
                    return nil
                }
                do {
                    segments = try discoverSegments()
                    try _onSegmentsDiscoveredForTesting?()
                } catch {
                    terminate()
                    throw error
                }
            }
            while !terminated {
                if Task.isCancelled {
                    terminate()
                    return nil
                }
                if currentScanner != nil {
                    if let bytes = try pullNextOutcome() { return bytes }
                    continue
                }
                guard try advanceToNextSegment() else { return nil }
            }
            return nil
        }

        /// Advances `currentScanner` by one outcome. Returns the
        /// accepted line's bytes, or `nil` when the current segment
        /// is exhausted (caller should advance).
        private func pullNextOutcome() throws -> Data? {
            guard var scanner = currentScanner else { return nil }
            let outcome: RecoverablePrefixScanner.LineOutcome?
            do {
                outcome = try scanner.next()
                currentScanner = scanner
            } catch {
                terminate()
                throw error
            }
            guard let outcome else {
                releaseCurrentSegment()
                return nil
            }
            switch outcome {
            case let .accepted(_, bytes):
                return bytes
            case .trailingPartial:
                // Trailing partial bytes are recoverable only on
                // the final segment. If a later segment exists, the
                // partial suffix sits in the middle of the segment
                // chain and bytes beyond it are no longer part of
                // the recoverable prefix.
                if hasLaterSegment() {
                    let segment = currentSegmentURL ?? configuration.directory
                    terminate()
                    throw InternalReadError.operationFailed(
                        operation: .readSegmentBytes,
                        url: segment,
                        context: FileSystemErrorContext(
                            domain: FileSystemErrorContext.packageDomain,
                            code: nil,
                            description: "trailingPartialInNonFinalSegment"
                        )
                    )
                }
                releaseCurrentSegment()
                return nil
            case let .corrupt(byteOffset, classification):
                let segment = currentSegmentURL ?? configuration.directory
                terminate()
                throw InternalReadError.interiorCorruption(
                    segmentURL: segment,
                    byteOffset: byteOffset,
                    classification: classification
                )
            }
        }

        private func hasLaterSegment() -> Bool {
            guard let urls = segments else { return false }
            return nextSegmentIndex < urls.count
        }

        /// Opens the next segment's handle + scanner via the held
        /// `SegmentRoot` so segment opens use `openat(rootFD, name,
        /// O_NOFOLLOW)`. Returns `false` when no more segments remain.
        private func advanceToNextSegment() throws -> Bool {
            guard let urls = segments, nextSegmentIndex < urls.count else {
                terminate()
                return false
            }
            guard let root else {
                terminate()
                return false
            }
            // Retry deferred-close handles before taking on a new
            // segment; the previous segment's failed close is given
            // one more chance at this iterator boundary.
            drainPendingCloseHandles()
            let url = urls[nextSegmentIndex]
            nextSegmentIndex += 1
            currentSegmentURL = url
            let openedHandle = try root.openSegmentForReading(url: url)
            currentHandle = openedHandle
            do {
                currentScanner = try RecoverablePrefixScanner.iterator(
                    handle: openedHandle,
                    segmentURL: url
                )
            } catch {
                releaseCurrentSegment()
                terminate()
                throw error
            }
            return true
        }

        /// Opens the configured root and discovers the segment URLs
        /// it contains. The opened root is retained on `self` so
        /// subsequent segment opens remain descriptor-relative.
        private func discoverSegments() throws -> [URL] {
            let openedRoot = try SegmentRoot.open(directory: configuration.directory)
            root = openedRoot
            guard let openedRoot else { return [] }
            switch configuration.rotation.kind {
            case .never:
                let url = try openedRoot.unrotatedSegmentURLIfRegular()
                return url.map { [$0] } ?? []
            case .bySize:
                return try openedRoot.enumerateRotatedSegments().map(\.url)
            }
        }

        private func releaseCurrentSegment() {
            let hadOpenSegment = currentHandle != nil || currentScanner != nil
            if let scanner = currentScanner {
                aggregateChunkReads += scanner.chunkReadCountForTesting
            }
            currentScanner = nil
            if let handle = currentHandle {
                closeCurrentHandleForDeferredCleanup(handle)
            }
            currentHandle = nil
            currentSegmentURL = nil
            if hadOpenSegment {
                _releaseObserverForTesting?()
            }
        }

        /// Closes the per-segment read handle. Close failure
        /// retains the handle in the iterator-local queue so
        /// the failure is not silently dropped between segments.
        private func closeCurrentHandleForDeferredCleanup(_ handle: FileHandle) {
            do {
                try handle.close()
            } catch {
                pendingCloseHandles.append(handle)
            }
        }

        /// Retries every pending-close handle once. Handles
        /// whose retry still fails stay queued for the next
        /// boundary; on `deinit` the leftover queue is dropped
        /// as the final best-effort attempt.
        private func drainPendingCloseHandles() {
            guard !pendingCloseHandles.isEmpty else { return }
            let handles = pendingCloseHandles
            pendingCloseHandles = []
            for handle in handles {
                do {
                    try handle.close()
                } catch {
                    pendingCloseHandles.append(handle)
                }
            }
        }

        private func terminate() {
            releaseCurrentSegment()
            drainPendingCloseHandles()
            root?.close()
            root = nil
            terminated = true
        }
    }
}
