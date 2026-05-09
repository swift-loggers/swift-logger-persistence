import Darwin
import Foundation

/// Internal helpers for filename-based rotated-segment enumeration.
///
/// Rotated segments use the layout `log.<digits>.ndjson` with a
/// positive ASCII-decimal sequence. Enumeration is filename-driven and
/// width-independent so reopen survives operator-edited padding.
/// Filename parsing and regular-file filtering live here only;
/// other types must not duplicate the rules.
internal enum SegmentEnumeration {
    /// Filename used when ``RotationPolicy/never`` is configured.
    static let unrotatedSegmentFileName = "log.ndjson"

    /// Filename prefix shared by all rotated segments.
    static let rotatedSegmentFileNamePrefix = "log."

    /// Filename suffix shared by all rotated segments.
    static let rotatedSegmentFileNameSuffix = ".ndjson"

    /// Returns the unrotated-segment URL under `directory`.
    static func unrotatedSegmentURL(in directory: URL) -> URL {
        directory.appendingPathComponent(unrotatedSegmentFileName)
    }

    /// Returns the unrotated-segment URL when `log.ndjson` is
    /// present and is a regular file. Single-call wrapper around
    /// ``SegmentRoot``: opens the configured root as a
    /// descriptor-relative discovery root, inspects the entry
    /// descriptor-relatively, and releases the descriptor before
    /// returning.
    static func unrotatedSegmentURLIfRegular(
        in directory: URL,
        fileManager _: FileManager
    ) throws(InternalReadError) -> URL? {
        guard let root = try SegmentRoot.open(directory: directory)
        else { return nil }
        defer { root.close() }
        return try root.unrotatedSegmentURLIfRegular()
    }

    /// Returns rotated segments under `directory` as
    /// `(url, sequence)` pairs in numeric sequence ascending
    /// order. Single-call wrapper around ``SegmentRoot``.
    static func enumerateRotatedSegments(
        in directory: URL,
        fileManager _: FileManager
    ) throws(InternalReadError) -> [(url: URL, sequence: UInt64)] {
        guard let root = try SegmentRoot.open(directory: directory)
        else { return [] }
        defer { root.close() }
        return try root.enumerateRotatedSegments()
    }

    /// Returns the highest rotated-segment sequence under
    /// `directory`, or `nil` when none exist. Single-call wrapper
    /// around ``SegmentRoot``.
    static func highestRotatedSegmentSequence(
        in directory: URL,
        fileManager _: FileManager
    ) throws(InternalReadError) -> UInt64? {
        guard let root = try SegmentRoot.open(directory: directory)
        else { return nil }
        defer { root.close() }
        return try root.highestRotatedSegmentSequence()
    }

    /// Returns the write-side rotated-segment URL for `sequence`.
    static func rotatedSegmentURL(
        in directory: URL,
        sequence: UInt64,
        minimumWidth: Int
    ) -> URL {
        var digits = String(sequence)
        while digits.utf8.count < minimumWidth {
            digits = "0" + digits
        }
        let name = rotatedSegmentFileNamePrefix
            + digits
            + rotatedSegmentFileNameSuffix
        return directory.appendingPathComponent(name)
    }

    /// Parses a rotated-segment sequence from `name` if the name
    /// matches `log.<positive-decimal>.ndjson`. Returns `nil` for
    /// non-matching names.
    static func parsedSequence(in name: String) -> UInt64? {
        guard name.hasPrefix(rotatedSegmentFileNamePrefix),
              name.hasSuffix(rotatedSegmentFileNameSuffix)
        else { return nil }
        let middle = name
            .dropFirst(rotatedSegmentFileNamePrefix.count)
            .dropLast(rotatedSegmentFileNameSuffix.count)
        guard !middle.isEmpty,
              middle.utf8.allSatisfy(isASCIIDigit)
        else { return nil }
        guard let sequence = UInt64(middle), sequence > 0 else { return nil }
        return sequence
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    /// Stable, package-owned identifier carried in
    /// `FileSystemErrorContext.description` of every
    /// duplicate-rotated-sequence rejection.
    internal static let duplicateRotatedSegmentSequenceMarker = "duplicateRotatedSegmentSequence"

    /// Returns `true` when `error` is the duplicate-
    /// rotated-sequence rejection produced by
    /// ``SegmentRoot/enumerateRotatedSegments()`` or
    /// ``SegmentRoot/highestRotatedSegmentSequence()``.
    /// Centralizes the classifier so consumers do not parse
    /// `FileSystemErrorContext.description` directly.
    internal static func isDuplicateRotatedSegmentSequenceError(
        _ error: InternalReadError
    ) -> Bool {
        guard case let .operationFailed(_, _, context) = error else {
            return false
        }
        return context.domain == FileSystemErrorContext.packageDomain
            && context.code == nil
            && context.description == duplicateRotatedSegmentSequenceMarker
    }
}

// MARK: - SegmentRoot (descriptor-relative discovery)

/// Stable directory identity captured from a filesystem
/// metadata snapshot.
internal struct DirectoryIdentity: Equatable, Sendable {
    // periphery:ignore - Periphery does not trace synthesized Equatable reads.
    let dev: dev_t
    // periphery:ignore - Periphery does not trace synthesized Equatable reads.
    let ino: ino_t

    /// Builds stable directory identity from a filesystem
    /// metadata snapshot.
    init(_ statBuf: stat) {
        dev = statBuf.st_dev
        ino = statBuf.st_ino
    }
}

/// Descriptor-relative handle for segment discovery and segment opens.
internal final class SegmentRoot: @unchecked Sendable {
    let directoryURL: URL
    internal private(set) var rootFD: Int32

    private init(directoryURL: URL, rootFD: Int32) {
        self.directoryURL = directoryURL
        self.rootFD = rootFD
    }

    deinit {
        if rootFD >= 0 {
            _ = Darwin.close(rootFD)
        }
    }

    /// Releases the root file descriptor. Subsequent discovery or
    /// segment-open calls on this instance are invalid.
    func close() {
        if rootFD >= 0 {
            _ = Darwin.close(rootFD)
            rootFD = -1
        }
    }

    /// Opens `directory` as a descriptor-relative discovery root.
    /// Returns `nil` for an absent root (`ENOENT`); throws
    /// `.operationFailed(.enumerateSegments)` for non-directory
    /// (`ENOTDIR`), symlinked root (`ELOOP`), or any other open
    /// failure.
    static func open(
        directory: URL
    ) throws(InternalReadError) -> SegmentRoot? {
        let descriptor = directory.path.withCString { cPath in
            Darwin.open(cPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            let savedErrno = errno
            if savedErrno == ENOENT {
                return nil
            }
            throw .operationFailed(
                operation: .enumerateSegments,
                url: directory,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "descriptor-relative root open failed"
                )
            )
        }
        return SegmentRoot(directoryURL: directory, rootFD: descriptor)
    }

    /// Asserts the held descriptor still refers to the same
    /// directory identity captured by `expected`. Used by the writer
    /// to bind pre-open directory validation to the held descriptor
    /// identity so a configured-path swap between validation and
    /// descriptor acquisition is rejected.
    func validateIdentity(
        matches expected: DirectoryIdentity
    ) throws(InternalReadError) {
        var statBuf = stat()
        if fstat(rootFD, &statBuf) != 0 {
            let savedErrno = errno
            throw .operationFailed(
                operation: .enumerateSegments,
                url: directoryURL,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "directory identity read failed"
                )
            )
        }
        let actual = DirectoryIdentity(statBuf)
        guard actual == expected else {
            throw .operationFailed(
                operation: .enumerateSegments,
                url: directoryURL,
                context: FileSystemErrorContext(
                    domain: FileSystemErrorContext.packageDomain,
                    code: nil,
                    description: "root identity mismatch"
                )
            )
        }
    }

    /// Returns the unrotated-segment URL when `log.ndjson` exists
    /// and is a regular file. Inspection is descriptor-relative;
    /// absent entry maps to `nil`; any other entry topology
    /// maps to `.operationFailed(.enumerateSegments)`.
    func unrotatedSegmentURLIfRegular() throws(InternalReadError) -> URL? {
        let name = SegmentEnumeration.unrotatedSegmentFileName
        let url = directoryURL.appendingPathComponent(name)
        guard let isRegular = try isRegularFile(name: name) else {
            return nil
        }
        guard isRegular else {
            throw .operationFailed(
                operation: .enumerateSegments,
                url: url,
                context: FileSystemErrorContext(
                    domain: FileSystemErrorContext.packageDomain,
                    code: nil,
                    description: "unrotated segment is not a regular file"
                )
            )
        }
        return url
    }

    /// Returns rotated segments in deterministic numeric order.
    /// Skips non-regular rotated entries and rejects duplicate
    /// numeric sequences with a deterministic diagnostic URL.
    func enumerateRotatedSegments() throws(InternalReadError) -> [(url: URL, sequence: UInt64)] {
        let names = try collectEntryNames()
        var matched: [(url: URL, sequence: UInt64)] = []
        for name in names {
            guard let sequence = SegmentEnumeration.parsedSequence(in: name)
            else { continue }
            guard try isRegularFile(name: name) == true else { continue }
            matched.append((directoryURL.appendingPathComponent(name), sequence))
        }
        matched.sort { lhs, rhs in
            if lhs.sequence != rhs.sequence {
                return lhs.sequence < rhs.sequence
            }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }
        for (previous, current) in zip(matched, matched.dropFirst())
            where previous.sequence == current.sequence {
            throw Self.duplicateRotatedSegmentFailure(previous.url, current.url)
        }
        return matched
    }

    /// Returns the highest rotated-segment sequence through
    /// descriptor-relative enumeration without materializing
    /// the full sorted segment list.
    ///
    /// Duplicate diagnostics are deterministic and match
    /// `enumerateRotatedSegments()`.
    func highestRotatedSegmentSequence() throws(InternalReadError) -> UInt64? {
        var tracker = DuplicateRotatedSegmentTracker()
        try forEachEntryName { name throws(InternalReadError) in
            guard let sequence = SegmentEnumeration.parsedSequence(in: name)
            else { return }
            guard try isRegularFile(name: name) == true else { return }
            tracker.observe(sequence: sequence, name: name)
        }
        if let duplicate = tracker.firstDuplicate() {
            throw Self.duplicateRotatedSegmentFailure(
                directoryURL.appendingPathComponent(duplicate.first),
                directoryURL.appendingPathComponent(duplicate.second)
            )
        }
        return tracker.maxSequence
    }

    /// Opens a segment for descriptor-relative reading and
    /// validates the resulting descriptor as a regular file.
    func openSegmentForReading(
        url: URL
    ) throws(InternalReadError) -> FileHandle {
        let descriptor = try openatRelative(
            url: url,
            flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC,
            mode: 0,
            failureDescription: "openat(O_RDONLY|O_NOFOLLOW) failed"
        )
        return try validateRegularFileFD(descriptor, url: url)
    }

    /// Opens or creates a writable segment without following symlinks
    /// and validates the descriptor as a regular file.
    func openSegmentForWriting(
        url: URL
    ) throws(InternalReadError) -> FileHandle {
        let descriptor = try openatRelative(
            url: url,
            flags: O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode: 0o666,
            failureDescription: "openat(O_RDWR|O_CREAT|O_NOFOLLOW) failed"
        )
        return try validateRegularFileFD(descriptor, url: url)
    }

    /// Resolves `url`'s last path component against `rootFD` and
    /// returns the opened descriptor. Failure projects to
    /// `.operationFailed(.openSegment)` with the supplied diagnostic.
    private func openatRelative(
        url: URL,
        flags: Int32,
        mode: mode_t,
        failureDescription: String
    ) throws(InternalReadError) -> Int32 {
        let descriptor = url.lastPathComponent.withCString { cName in
            Darwin.openat(rootFD, cName, flags, mode)
        }
        guard descriptor >= 0 else {
            let savedErrno = errno
            throw .operationFailed(
                operation: .openSegment,
                url: url,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: failureDescription
                )
            )
        }
        return descriptor
    }

    /// Streams directory entry names through `body` via a fresh
    /// directory stream opened with `openat(rootFD, ".", ...)` —
    /// see `openDirHandle` for why this avoids the
    /// shared-cursor bug that a `dup`-based open would
    /// reintroduce. Skips `.` and `..`; `body` is invoked once per
    /// remaining entry and may throw to abort the scan.
    private func forEachEntryName(
        _ body: (String) throws(InternalReadError) -> Void
    ) throws(InternalReadError) {
        let dirHandle = try openDirHandle()
        defer { closedir(dirHandle) }
        // `readdir` returns NULL on both EOF and error; the two are
        // distinguished only by inspecting `errno` after a NULL
        // return, with `errno` zeroed before the call.
        while true {
            errno = 0
            guard let entryPtr = readdir(dirHandle) else {
                if errno != 0 {
                    let savedErrno = errno
                    throw .operationFailed(
                        operation: .enumerateSegments,
                        url: directoryURL,
                        context: FileSystemErrorContext(
                            domain: NSPOSIXErrorDomain,
                            code: Int(savedErrno),
                            description: "readdir failed"
                        )
                    )
                }
                break
            }
            guard let name = decodeEntryName(entryPtr),
                  name != ".", name != ".."
            else { continue }
            try body(name)
        }
    }

    /// Opens a fresh `DIR *` over the held root via
    /// `openat(rootFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)` +
    /// `fdopendir`. Using `openat(".")` instead of `dup(rootFD)`
    /// gives the directory stream its own open-file description so
    /// `readdir` cursor advancement does not bleed back into
    /// `rootFD` (a `dup`'d descriptor would share the cursor and a
    /// later enumeration would resume at end-of-stream and report
    /// zero entries).
    private func openDirHandle() throws(InternalReadError) -> UnsafeMutablePointer<DIR> {
        let dirFD = ".".withCString { cDot in
            Darwin.openat(rootFD, cDot, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        if dirFD < 0 {
            let savedErrno = errno
            throw .operationFailed(
                operation: .enumerateSegments,
                url: directoryURL,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "openat(rootFD, \".\", O_RDONLY|O_DIRECTORY|O_CLOEXEC) failed"
                )
            )
        }
        guard let dirHandle = fdopendir(dirFD) else {
            let savedErrno = errno
            // Best-effort cleanup before throwing; close failure
            // does not change the projected enumerate-segments error.
            _ = Darwin.close(dirFD)
            throw .operationFailed(
                operation: .enumerateSegments,
                url: directoryURL,
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "fdopendir failed"
                )
            )
        }
        return dirHandle
    }

    /// Materializes the directory listing for callers that need
    /// random access — currently only the deterministic-order
    /// candidate sort in ``enumerateRotatedSegments()``. The
    /// streaming-only ``highestRotatedSegmentSequence()`` does not
    /// go through this path.
    private func collectEntryNames() throws(InternalReadError) -> [String] {
        var names: [String] = []
        try forEachEntryName { name in
            names.append(name)
        }
        return names
    }

    /// Returns whether the named entry under `rootFD` is a regular
    /// file. `nil` reports a vanished entry (`ENOENT`, e.g. race
    /// between listing and inspection).
    private func isRegularFile(name: String) throws(InternalReadError) -> Bool? {
        var statBuf = stat()
        let result = name.withCString { cName in
            fstatat(rootFD, cName, &statBuf, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            let savedErrno = errno
            if savedErrno == ENOENT { return nil }
            throw .operationFailed(
                operation: .enumerateSegments,
                url: directoryURL.appendingPathComponent(name),
                context: FileSystemErrorContext(
                    domain: NSPOSIXErrorDomain,
                    code: Int(savedErrno),
                    description: "fstatatFailed"
                )
            )
        }
        return (statBuf.st_mode & S_IFMT) == S_IFREG
    }

    private static func duplicateRotatedSegmentFailure(
        _ lhs: URL,
        _ rhs: URL
    ) -> InternalReadError {
        let url = lhs.lastPathComponent < rhs.lastPathComponent ? rhs : lhs
        return .operationFailed(
            operation: .enumerateSegments,
            url: url,
            context: FileSystemErrorContext(
                domain: FileSystemErrorContext.packageDomain,
                code: nil,
                description: SegmentEnumeration.duplicateRotatedSegmentSequenceMarker
            )
        )
    }
}

// MARK: - File-scope SegmentRoot helpers

/// Confirms `descriptor` refers to a regular file via `fstat` and
/// wraps it in an owning `FileHandle`. Closes the descriptor on
/// any rejection so the caller never leaks an FD. File-scope so
/// it does not occupy ``SegmentRoot`` body length; it does not
/// reference the held `rootFD`.
private func validateRegularFileFD(
    _ descriptor: Int32,
    url: URL
) throws(InternalReadError) -> FileHandle {
    var statBuf = stat()
    if fstat(descriptor, &statBuf) != 0 {
        let savedErrno = errno
        // Best-effort cleanup before throwing; close failure
        // does not change the projected open-segment error.
        _ = Darwin.close(descriptor)
        throw .operationFailed(
            operation: .openSegment,
            url: url,
            context: FileSystemErrorContext(
                domain: NSPOSIXErrorDomain,
                code: Int(savedErrno),
                description: "fstatFailed"
            )
        )
    }
    guard (statBuf.st_mode & S_IFMT) == S_IFREG else {
        // Best-effort cleanup before throwing; close failure
        // does not change the projected open-segment error.
        _ = Darwin.close(descriptor)
        throw .operationFailed(
            operation: .openSegment,
            url: url,
            context: FileSystemErrorContext(
                domain: FileSystemErrorContext.packageDomain,
                code: nil,
                description: "segmentNotRegularFile"
            )
        )
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

/// Decodes a `dirent`'s `d_name` field as UTF-8. Returns `nil`
/// when the on-disk bytes are not valid UTF-8; such entries are
/// not segment files and are silently skipped.
private func decodeEntryName(
    _ entryPtr: UnsafeMutablePointer<dirent>
) -> String? {
    let length = Int(entryPtr.pointee.d_namlen)
    var nameTuple = entryPtr.pointee.d_name
    return withUnsafeBytes(of: &nameTuple) { raw -> String? in
        guard let base = raw.baseAddress else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        return String(
            bytes: UnsafeBufferPointer(start: bytes, count: length),
            encoding: .utf8
        )
    }
}

// MARK: - DuplicateRotatedSegmentTracker

/// Streaming companion to ``SegmentRoot/highestRotatedSegmentSequence()``.
/// Records observed `(sequence, name)` pairs in O(1) amortized time
/// per observation and answers "is there a duplicate, and which
/// pair would be reported?" deterministically — independent of the
/// `readdir` order in which observations arrived.
///
/// Per sequence, the tracker keeps only the two lex-smallest
/// regular-file spellings seen so far; later spellings strictly
/// greater than the running second-smallest are discarded. After
/// the scan completes, ``firstDuplicate()`` returns the smallest
/// numeric sequence that has at least two spellings, alongside
/// those two lex-smallest spellings. Callers project that pair
/// onto the same diagnostic URL that
/// ``SegmentRoot/enumerateRotatedSegments()`` would report after
/// its `(sequence, lastPathComponent)` sort.
internal struct DuplicateRotatedSegmentTracker {
    /// Two lex-smallest spellings observed for one sequence,
    /// alongside that sequence — the diagnostic payload for a
    /// detected duplicate.
    internal struct Duplicate: Equatable {
        let sequence: UInt64
        let first: String
        let second: String
    }

    fileprivate struct SmallestPair {
        var first: String
        var second: String?
    }

    private var spellingsBySequence: [UInt64: SmallestPair] = [:]
    private(set) var maxSequence: UInt64?

    /// Records `name` as a regular-file spelling of `sequence` and
    /// updates ``maxSequence``. Maintains the two lex-smallest
    /// spellings seen so far per sequence.
    mutating func observe(sequence: UInt64, name: String) {
        if var pair = spellingsBySequence[sequence] {
            if name < pair.first {
                pair.second = pair.first
                pair.first = name
            } else if let second = pair.second {
                if name < second {
                    pair.second = name
                }
                // Otherwise `name` >= `second`; the running pair is
                // already the two lex-smallest and we discard.
            } else {
                // `readdir` does not return the same name twice
                // within one scan, so `name` > `pair.first` here.
                pair.second = name
            }
            spellingsBySequence[sequence] = pair
        } else {
            spellingsBySequence[sequence] = SmallestPair(first: name, second: nil)
        }
        if let current = maxSequence {
            maxSequence = Swift.max(current, sequence)
        } else {
            maxSequence = sequence
        }
    }

    /// Returns the smallest numeric sequence for which two or more
    /// regular-file spellings were observed, alongside the two
    /// lex-smallest spellings for that sequence. Returns `nil`
    /// when no duplicate was seen.
    func firstDuplicate() -> Duplicate? {
        var smallest: Duplicate?
        for (sequence, pair) in spellingsBySequence {
            guard let second = pair.second else { continue }
            if let current = smallest, sequence >= current.sequence { continue }
            smallest = Duplicate(sequence: sequence, first: pair.first, second: second)
        }
        return smallest
    }
}
