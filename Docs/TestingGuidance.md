# Testing Guidance

Non-normative test guidance for `swift-logger-persistence`.

## FileSystemErrorContext

`FileSystemErrorContext` is `Equatable` so tests can assert
fixture-created contexts and exact projected values. That conformance is
not a recommendation to compare runtime filesystem errors wholesale.

Runtime filesystem error tests should assert `FileLogStoreOperation`,
`domain`, and `code` independently. Treat `description` as
human-readable context only: it may be localized, may include filesystem
paths, volume names, user-provided path components, or OS-generated
diagnostic details, and may vary across OS/Foundation versions.

Do not snapshot the whole `FileSystemErrorContext` value unless the test
intentionally constructs the value itself as a fixture.
