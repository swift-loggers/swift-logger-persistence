import Foundation

/// Recursive duplicate-member detector for JSON object bytes after structural JSON acceptance.
///
/// Not a standalone JSON validator. Malformed JSON is classified
/// by the caller; this scanner walks already-accepted object bytes
/// and reports the first duplicate member name observed at any
/// object depth.
internal enum JSONDuplicateMemberScanner {
    internal enum Outcome: Equatable {
        case noDuplicate
        case duplicateMember
    }

    static func scan(objectBody: Data) -> Outcome {
        var walker = ByteWalker(bytes: objectBody)
        walker.skipWhitespace()
        guard walker.peek() == 0x7B else { return .noDuplicate }
        let outcome = walker.scanObject()
        guard outcome == .noDuplicate else { return outcome }
        walker.skipWhitespace()
        return .noDuplicate
    }
}

/// Walks the bytes of a `Data` slice without materializing them.
///
/// `pos` is a `Data.Index`; `bytes.startIndex` is non-zero when the
/// caller passes a slice (e.g. `lineWithLF.dropLast()`).
private struct ByteWalker {
    let bytes: Data
    var pos: Data.Index

    init(bytes: Data) {
        self.bytes = bytes
        pos = bytes.startIndex
    }

    func peek() -> UInt8? {
        pos < bytes.endIndex ? bytes[pos] : nil
    }

    mutating func skipWhitespace() {
        while pos < bytes.endIndex {
            switch bytes[pos] {
            case 0x20, 0x09, 0x0A, 0x0D:
                pos += 1
            default:
                return
            }
        }
    }

    /// Walks an object starting at `{` and reports duplicates at
    /// this scope or in any nested object.
    mutating func scanObject() -> JSONDuplicateMemberScanner.Outcome {
        guard peek() == 0x7B else { return .noDuplicate }
        pos += 1
        skipWhitespace()
        if peek() == 0x7D { pos += 1; return .noDuplicate }

        var seenNames = Set<String>()
        while pos < bytes.endIndex {
            switch scanNextMember(seenNames: &seenNames) {
            case .continueScanning:
                continue
            case .endOfObject:
                return .noDuplicate
            case .duplicateMember:
                return .duplicateMember
            }
        }
        return .noDuplicate
    }

    private enum MemberStepOutcome {
        case continueScanning
        case endOfObject
        case duplicateMember
    }

    private enum ValueOutcome {
        case valid
        case malformed
        case duplicateMember
    }

    private mutating func scanNextMember(
        seenNames: inout Set<String>
    ) -> MemberStepOutcome {
        skipWhitespace()
        guard let name = parseString() else { return .endOfObject }
        if !seenNames.insert(name).inserted { return .duplicateMember }
        skipWhitespace()
        guard peek() == 0x3A else { return .endOfObject }
        pos += 1
        skipWhitespace()
        switch scanValue() {
        case .valid: break
        case .malformed: return .endOfObject
        case .duplicateMember: return .duplicateMember
        }
        skipWhitespace()
        switch peek() {
        case 0x2C: pos += 1; return .continueScanning
        case 0x7D: pos += 1; return .endOfObject
        default: return .endOfObject
        }
    }

    /// Walks one JSON value, recursing into nested objects/arrays
    /// so duplicate detection runs at every object depth.
    private mutating func scanValue() -> ValueOutcome {
        skipWhitespace()
        guard let byte = peek() else { return .malformed }
        switch byte {
        case 0x22:
            return parseString() != nil ? .valid : .malformed
        case 0x7B:
            switch scanObject() {
            case .duplicateMember: return .duplicateMember
            case .noDuplicate: return .valid
            }
        case 0x5B:
            return scanArray()
        case 0x74, 0x66, 0x6E:
            return parseKeyword() ? .valid : .malformed
        default:
            if byte == 0x2D || (0x30 ... 0x39).contains(byte) {
                return parseNumber() ? .valid : .malformed
            }
            return .malformed
        }
    }

    private mutating func scanArray() -> ValueOutcome {
        guard peek() == 0x5B else { return .malformed }
        pos += 1
        skipWhitespace()
        if peek() == 0x5D { pos += 1; return .valid }
        while pos < bytes.endIndex {
            switch scanValue() {
            case .valid: break
            case .malformed: return .malformed
            case .duplicateMember: return .duplicateMember
            }
            skipWhitespace()
            switch peek() {
            case 0x2C: pos += 1; continue
            case 0x5D: pos += 1; return .valid
            default: return .malformed
            }
        }
        return .malformed
    }

    /// Matches `true`, `false`, or `null` at the cursor.
    private mutating func parseKeyword() -> Bool {
        guard let first = peek() else { return false }
        let token: [UInt8]
        switch first {
        case 0x74: token = [0x74, 0x72, 0x75, 0x65]
        case 0x66: token = [0x66, 0x61, 0x6C, 0x73, 0x65]
        case 0x6E: token = [0x6E, 0x75, 0x6C, 0x6C]
        default: return false
        }
        guard pos + token.count <= bytes.endIndex else { return false }
        for offset in 0 ..< token.count where bytes[pos + offset] != token[offset] {
            return false
        }
        pos += token.count
        return atValueBoundary()
    }

    /// Parses one JSON number.
    private mutating func parseNumber() -> Bool {
        if peek() == 0x2D { pos += 1 }
        guard let leading = peek(), (0x30 ... 0x39).contains(leading) else {
            return false
        }
        if leading == 0x30 {
            pos += 1
        } else {
            pos += 1
            consumeDigits()
        }
        if peek() == 0x2E {
            pos += 1
            guard let frac = peek(), (0x30 ... 0x39).contains(frac) else {
                return false
            }
            consumeDigits()
        }
        if let expByte = peek(), expByte == 0x65 || expByte == 0x45 {
            pos += 1
            if let sign = peek(), sign == 0x2B || sign == 0x2D { pos += 1 }
            guard let expDigit = peek(), (0x30 ... 0x39).contains(expDigit) else {
                return false
            }
            consumeDigits()
        }
        return atValueBoundary()
    }

    private mutating func consumeDigits() {
        while let byte = peek(), (0x30 ... 0x39).contains(byte) {
            pos += 1
        }
    }

    /// A value token's trailing position must be EOF or one of
    /// `,`, `}`, `]`, or JSON whitespace.
    private func atValueBoundary() -> Bool {
        guard let byte = peek() else { return true }
        switch byte {
        case 0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x7D, 0x5D:
            return true
        default:
            return false
        }
    }

    /// Returns the decoded contents of a JSON string. Duplicate
    /// detection compares decoded names, not raw bytes.
    mutating func parseString() -> String? {
        guard peek() == 0x22 else { return nil }
        pos += 1
        var decoded = [UInt8]()
        while pos < bytes.endIndex {
            let byte = bytes[pos]
            if byte == 0x22 {
                pos += 1
                return String(bytes: decoded, encoding: .utf8)
            }
            if byte == 0x5C {
                pos += 1
                guard appendEscapedSequence(into: &decoded) else { return nil }
                continue
            }
            if byte < 0x20 { return nil }
            decoded.append(byte)
            pos += 1
        }
        return nil
    }

    mutating func appendEscapedSequence(
        into output: inout [UInt8]
    ) -> Bool {
        guard pos < bytes.endIndex else { return false }
        let escape = bytes[pos]
        pos += 1
        switch escape {
        case 0x22, 0x5C, 0x2F:
            output.append(escape)
            return true
        case 0x62: output.append(0x08); return true
        case 0x66: output.append(0x0C); return true
        case 0x6E: output.append(0x0A); return true
        case 0x72: output.append(0x0D); return true
        case 0x74: output.append(0x09); return true
        case 0x75:
            return decodeUnicodeEscape(into: &output)
        default:
            return false
        }
    }

    /// Decodes one `\uXXXX` escape into UTF-8. Returns `false` for
    /// an unpaired surrogate.
    mutating func decodeUnicodeEscape(into output: inout [UInt8]) -> Bool {
        guard let leading = readFourHexDigits() else { return false }
        if (0xD8_00 ... 0xDB_FF).contains(leading) {
            guard peekLowSurrogateEscape() else { return false }
            pos += 2
            guard let trailing = readFourHexDigits(),
                  (0xDC_00 ... 0xDF_FF).contains(trailing)
            else { return false }
            let codepoint = 0x1_00_00
                + ((leading - 0xD8_00) << 10)
                + (trailing - 0xDC_00)
            appendUTF8(codepoint, to: &output)
            return true
        }
        if (0xDC_00 ... 0xDF_FF).contains(leading) { return false }
        appendUTF8(leading, to: &output)
        return true
    }

    /// Reads four ASCII hex digits and returns their UInt32 value.
    /// Rejects any byte outside `[0-9A-Fa-f]`.
    private mutating func readFourHexDigits() -> UInt32? {
        guard pos + 4 <= bytes.endIndex else { return nil }
        var value: UInt32 = 0
        for offset in 0 ..< 4 {
            guard let digit = Self.asciiHexDigitValue(bytes[pos + offset]) else {
                return nil
            }
            value = (value << 4) | digit
        }
        pos += 4
        return value
    }

    private static func asciiHexDigitValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 0x30 ... 0x39: return UInt32(byte - 0x30)
        case 0x41 ... 0x46: return UInt32(byte - 0x41 + 10)
        case 0x61 ... 0x66: return UInt32(byte - 0x61 + 10)
        default: return nil
        }
    }

    private func peekLowSurrogateEscape() -> Bool {
        guard pos + 2 <= bytes.endIndex else { return false }
        return bytes[pos] == 0x5C && bytes[pos + 1] == 0x75
    }
}

/// Encodes a non-surrogate Unicode scalar as UTF-8.
private func appendUTF8(
    _ codepoint: UInt32,
    to output: inout [UInt8]
) {
    if codepoint < 0x80 {
        output.append(UInt8(codepoint))
    } else if codepoint < 0x800 {
        output.append(UInt8(0xC0 | (codepoint >> 6)))
        output.append(UInt8(0x80 | (codepoint & 0x3F)))
    } else if codepoint < 0x1_00_00 {
        output.append(UInt8(0xE0 | (codepoint >> 12)))
        output.append(UInt8(0x80 | ((codepoint >> 6) & 0x3F)))
        output.append(UInt8(0x80 | (codepoint & 0x3F)))
    } else {
        output.append(UInt8(0xF0 | (codepoint >> 18)))
        output.append(UInt8(0x80 | ((codepoint >> 12) & 0x3F)))
        output.append(UInt8(0x80 | ((codepoint >> 6) & 0x3F)))
        output.append(UInt8(0x80 | (codepoint & 0x3F)))
    }
}
