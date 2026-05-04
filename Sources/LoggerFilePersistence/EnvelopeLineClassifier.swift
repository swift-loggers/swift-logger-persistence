import Foundation
@_spi(WireFormat) import LoggerPersistence

/// Classifies one LF-terminated envelope line.
///
/// Accepted lines must match the canonical producer bytes exactly.
/// Corruption classification follows the file-format precedence.
internal enum EnvelopeLineClassifier {
    internal enum Outcome: Equatable {
        case accepted
        case corrupt(InternalCorruptionClass)
    }

    static func classify(_ lineWithLF: Data) -> Outcome {
        guard lineWithLF.last == 0x0A else {
            // Caller invariant violation; classify as corrupt to
            // keep the read path total.
            return .corrupt(.invalidDelimiter)
        }
        let body = lineWithLF.dropLast()
        if let preEnvelope = preEnvelopeOutcome(body) { return preEnvelope }
        return envelopeOutcome(body, lineWithLF: lineWithLF)
    }

    /// Performs corruption checks before envelope-shape validation.
    private static func preEnvelopeOutcome(_ body: Data) -> Outcome? {
        guard String(data: body, encoding: .utf8) != nil else {
            return .corrupt(.malformedUTF8)
        }
        if body.last == 0x0D { return .corrupt(.invalidDelimiter) }
        let parsed: Any
        do {
            // `.fragmentsAllowed` so top-level non-object JSON
            // (`true`, `null`, `123`, `"abc"`, `[]`) parses as a
            // valid fragment instead of a parse error; the
            // non-object case is then classified separately.
            parsed = try JSONSerialization.jsonObject(
                with: body, options: [.fragmentsAllowed]
            )
        } catch {
            return .corrupt(.malformedJSON)
        }
        guard parsed is [String: Any] else { return .corrupt(.nonObjectJSON) }
        if JSONDuplicateMemberScanner.scan(objectBody: body) == .duplicateMember {
            return .corrupt(.duplicateJSONMember)
        }
        return nil
    }

    /// Validates envelope shape and canonical byte identity.
    private static func envelopeOutcome(_ body: Data, lineWithLF: Data) -> Outcome {
        guard let shaped = try? JSONDecoder().decode(ShapedEnvelope.self, from: body) else {
            return .corrupt(.invalidEnvelope)
        }
        guard let payload = Data(base64Encoded: shaped.payload) else {
            return .corrupt(.malformedBase64)
        }
        guard let id = Self.parseCanonicalEnvelopeID(shaped.id),
              let createdAt = Self.parseCanonicalCreatedAt(shaped.createdAt)
        else {
            return .corrupt(.invalidEnvelope)
        }
        let envelope: PersistentLogEnvelope
        do {
            envelope = try PersistentLogEnvelope(
                id: id,
                sequence: shaped.sequence,
                createdAt: createdAt,
                contentType: shaped.contentType,
                hints: shaped.hints,
                payload: payload
            )
        } catch {
            return .corrupt(.invalidEnvelope)
        }
        let canonical: Data
        do {
            canonical = try CanonicalEnvelopeLineEncoder().encode(envelope)
        } catch {
            return .corrupt(.invalidEnvelope)
        }
        guard canonical == lineWithLF else {
            return .corrupt(.invalidEnvelope)
        }
        return .accepted
    }

    /// Parses canonical envelope UUID spelling.
    private static func parseCanonicalEnvelopeID(_ string: String) -> UUID? {
        let bytes = Array(string.utf8)
        guard bytes.count == 36 else { return nil }
        for index in 0 ..< bytes.count {
            let byte = bytes[index]
            if index == 8 || index == 13 || index == 18 || index == 23 {
                guard byte == 0x2D else { return nil }
            } else {
                let isDigit = (0x30 ... 0x39).contains(byte)
                let isLowerHex = (0x61 ... 0x66).contains(byte)
                guard isDigit || isLowerHex else { return nil }
            }
        }
        return UUID(uuidString: string)
    }

    /// Parses canonical millisecond UTC timestamp spelling.
    private static func parseCanonicalCreatedAt(_ string: String) -> Date? {
        let bytes = Array(string.utf8)
        guard bytes.count == 24 else { return nil }
        guard bytes[4] == 0x2D, bytes[7] == 0x2D,
              bytes[10] == 0x54,
              bytes[13] == 0x3A, bytes[16] == 0x3A,
              bytes[19] == 0x2E,
              bytes[23] == 0x5A
        else { return nil }
        for index in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18, 20, 21, 22] {
            guard (0x30 ... 0x39).contains(bytes[index]) else { return nil }
        }
        func decimal(_ start: Int, _ length: Int) -> Int {
            var value = 0
            for index in start ..< start + length {
                value = value * 10 + Int(bytes[index] - 0x30)
            }
            return value
        }
        var components = DateComponents()
        components.year = decimal(0, 4)
        components.month = decimal(5, 2)
        components.day = decimal(8, 2)
        components.hour = decimal(11, 2)
        components.minute = decimal(14, 2)
        components.second = decimal(17, 2)
        components.nanosecond = decimal(20, 3) * 1_000_000
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = utc
        guard let date = calendar.date(from: components) else { return nil }
        guard CanonicalTimestamp.canonicalString(from: date) == string else {
            return nil
        }
        return date
    }
}

/// Strict decoded envelope shape.
private struct ShapedEnvelope: Decodable {
    let id: String
    let sequence: UInt64
    let createdAt: String
    let contentType: String
    let hints: [String: String]
    let payload: String
}
