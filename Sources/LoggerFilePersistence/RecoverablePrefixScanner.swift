import Foundation

/// Synchronous byte-stable recoverable-prefix scanner.
internal enum RecoverablePrefixScanner {
    internal enum LineOutcome: Equatable {
        /// Complete accepted line including trailing LF. The bytes
        /// are the line as buffered during scanning, so accepted-line
        /// consumers do not reread the segment.
        case accepted(byteOffset: UInt64, bytes: Data)
        /// Recoverable-prefix boundary where non-LF tail begins.
        case trailingPartial(byteOffset: UInt64)
        /// Terminal interior-corruption boundary; no further outcomes follow.
        case corrupt(byteOffset: UInt64, classification: InternalCorruptionClass)
    }

    /// Writer-reopen recoverable-prefix resolution.
    internal enum BoundaryResolution: Equatable {
        case boundary(UInt64)
        case interiorCorruption(byteOffset: UInt64, classification: InternalCorruptionClass)
    }

    fileprivate static let chunkSize: Int = 64 * 1024

    /// Returns a pull-based iterator over recoverable-prefix outcomes.
    static func iterator(
        handle: FileHandle,
        segmentURL: URL
    ) throws(InternalReadError) -> Iterator {
        try Iterator(handle: handle, segmentURL: segmentURL)
    }

    /// Resolves the writer-reopen recoverable-prefix boundary.
    static func resolveBoundary(
        handle: FileHandle,
        segmentURL: URL
    ) throws(InternalReadError) -> BoundaryResolution {
        var iterator = try Iterator(handle: handle, segmentURL: segmentURL)
        var boundary: UInt64 = 0
        while let outcome = try iterator.next() {
            switch outcome {
            case let .accepted(byteOffset, bytes):
                let (next, overflow) = byteOffset
                    .addingReportingOverflow(UInt64(bytes.count))
                guard !overflow else {
                    throw .operationFailed(
                        operation: .readSegmentBytes,
                        url: segmentURL,
                        context: FileSystemErrorContext(
                            domain: FileSystemErrorContext.packageDomain,
                            code: nil,
                            description: "lineOffsetOverflow"
                        )
                    )
                }
                boundary = next
            case let .trailingPartial(byteOffset):
                boundary = byteOffset
            case let .corrupt(byteOffset, classification):
                return .interiorCorruption(
                    byteOffset: byteOffset,
                    classification: classification
                )
            }
        }
        return .boundary(boundary)
    }
}

extension RecoverablePrefixScanner {
    /// Pull-based scanner iterator.
    internal struct Iterator {
        private let handle: FileHandle
        private let segmentURL: URL
        private var lineStart: UInt64
        private var lineByteCount: Int
        private var lineBuffer: Data
        private var pendingChunk: Data
        private var pendingCursor: Data.Index
        private var atEOF: Bool
        private var terminated: Bool
        private var instrumentedChunkReadCount: Int

        /// TEST-ONLY chunk-read counter.
        internal var chunkReadCountForTesting: Int { instrumentedChunkReadCount }

        fileprivate init(
            handle: FileHandle,
            segmentURL: URL
        ) throws(InternalReadError) {
            self.handle = handle
            self.segmentURL = segmentURL
            lineStart = 0
            lineByteCount = 0
            lineBuffer = Data()
            pendingChunk = Data()
            pendingCursor = 0
            atEOF = false
            terminated = false
            instrumentedChunkReadCount = 0
            do {
                try handle.seek(toOffset: 0)
            } catch {
                throw .operationFailed(
                    operation: .openSegment,
                    url: segmentURL,
                    context: FileSystemErrorContext(from: error)
                )
            }
        }

        /// Returns the next outcome, or `nil` when the segment is
        /// fully scanned. After a `.corrupt` outcome, subsequent
        /// calls return `nil`.
        ///
        /// The scanner is cancellation-neutral: it does not observe
        /// `Task.isCancelled`. Writer reopen drives the scanner via
        /// ``RecoverablePrefixScanner/resolveBoundary(handle:segmentURL:)``
        /// and must always receive the full boundary or a typed
        /// corruption outcome, never a partial boundary masquerading
        /// as EOF. Read-side prompt cancellation is the iterator
        /// consumer's concern.
        mutating func next() throws(InternalReadError) -> LineOutcome? {
            if terminated { return nil }
            while true {
                if let outcome = try emitNextOutcomeFromPending() {
                    return outcome
                }
                if atEOF {
                    if lineByteCount > 0 {
                        let outcome: LineOutcome = .trailingPartial(byteOffset: lineStart)
                        lineByteCount = 0
                        terminated = true
                        return outcome
                    }
                    terminated = true
                    return nil
                }
                try fillPendingChunk()
            }
        }

        /// Tries to emit the next outcome from the buffered chunk.
        /// Returns `nil` when more bytes are required.
        private mutating func emitNextOutcomeFromPending() throws(InternalReadError) -> LineOutcome? {
            guard pendingCursor < pendingChunk.endIndex else { return nil }
            guard let lfIndex = pendingChunk[pendingCursor...].firstIndex(of: 0x0A) else {
                appendBoundedTail(pendingChunk[pendingCursor ..< pendingChunk.endIndex])
                pendingCursor = pendingChunk.endIndex
                return nil
            }
            appendBoundedTail(pendingChunk[pendingCursor ... lfIndex])
            let (next, overflow) = lineStart.addingReportingOverflow(UInt64(lineByteCount))
            guard !overflow else {
                terminated = true
                throw .operationFailed(
                    operation: .readSegmentBytes,
                    url: segmentURL,
                    context: FileSystemErrorContext(
                        domain: FileSystemErrorContext.packageDomain,
                        code: nil,
                        description: "lineOffsetOverflow"
                    )
                )
            }
            let outcome = classifyTerminatedLine()
            pendingCursor = pendingChunk.index(after: lfIndex)
            if case .corrupt = outcome {
                terminated = true
                return outcome
            }
            lineStart = next
            lineByteCount = 0
            lineBuffer.removeAll(keepingCapacity: true)
            return outcome
        }

        private mutating func fillPendingChunk() throws(InternalReadError) {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: RecoverablePrefixScanner.chunkSize)
            } catch {
                terminated = true
                throw .operationFailed(
                    operation: .readSegmentBytes,
                    url: segmentURL,
                    context: FileSystemErrorContext(from: error)
                )
            }
            if let chunk, !chunk.isEmpty {
                pendingChunk = chunk
                pendingCursor = chunk.startIndex
                instrumentedChunkReadCount += 1
            } else {
                atEOF = true
            }
        }

        /// Accumulates the slice's byte count into `lineByteCount`
        /// and appends to `lineBuffer` only up to the encoded-line
        /// cap. Bytes past the cap are counted but not buffered.
        /// Saturates `lineByteCount` to `Int.max` on overflow so the
        /// downstream cap check still hard-stops the line as
        /// `.invalidEnvelope`.
        private mutating func appendBoundedTail(_ slice: Data) {
            let (nextCount, overflow) = lineByteCount.addingReportingOverflow(slice.count)
            lineByteCount = overflow ? Int.max : nextCount
            let remainingCap = FileLogStore.maxEncodedLineBytes - lineBuffer.count
            guard remainingCap > 0 else { return }
            if slice.count <= remainingCap {
                lineBuffer.append(slice)
            } else {
                let endIndex = slice.startIndex + remainingCap
                lineBuffer.append(slice[slice.startIndex ..< endIndex])
            }
        }

        /// Classifies an LF-terminated line. Lines whose total byte
        /// count exceeds the encoded-line cap classify as terminal
        /// `.corrupt(.invalidEnvelope)` without invoking the
        /// classifier.
        private func classifyTerminatedLine() -> LineOutcome {
            if lineByteCount > FileLogStore.maxEncodedLineBytes {
                return .corrupt(byteOffset: lineStart, classification: .invalidEnvelope)
            }
            switch EnvelopeLineClassifier.classify(lineBuffer) {
            case .accepted:
                return .accepted(byteOffset: lineStart, bytes: lineBuffer)
            case let .corrupt(classification):
                return .corrupt(byteOffset: lineStart, classification: classification)
            }
        }
    }
}
