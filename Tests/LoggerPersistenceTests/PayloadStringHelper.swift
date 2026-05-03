import Foundation
import LoggerPersistence

/// Test-local typed error for envelopes whose payload bytes
/// are not valid UTF-8.
enum PayloadDecodingError: Error, Equatable {
    case malformedUTF8
}

/// Decodes a `PersistentLogEnvelope.payload` as UTF-8.
///
/// - Throws: ``PayloadDecodingError/malformedUTF8`` when the
///   payload bytes are not valid UTF-8.
func payloadString(_ envelope: PersistentLogEnvelope) throws -> String {
    guard let string = String(data: envelope.payload, encoding: .utf8) else {
        throw PayloadDecodingError.malformedUTF8
    }
    return string
}
