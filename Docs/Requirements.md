# Requirements

Lightweight traceability for `swift-logger-persistence`. Each requirement
carries an `LGP-N` identifier for ADRs, implementation work, and future
tests to reference. The "Target" column records the milestone or
documentation owner associated with the requirement; implementation
status is tracked by roadmap and coverage documents.

## Core API

| ID | Requirement | Target |
| --- | --- | --- |
| LGP-1 | Stores preserve caller-provided producer sequence. | M3.3.0 |
| LGP-2 | Store APIs expose I/O errors with `throws`. | M3.3.0 |
| LGP-3 | Adapters do not throw from `log`; diagnostics report failures. | Doc |
| LGP-4 | Default `LogRecord` persistence redacts before writing. | M3.3.0 |

## File Store Lifecycle

| ID | Requirement | Target |
| --- | --- | --- |
| LGP-5 | File store exposes `flush`. | M3.3.0 |
| LGP-6 | File store rotates by size. | M3.3.1 |
| LGP-7 | File store enforces retention. | M3.3.2 |
| LGP-8 | File store exports retained data byte-stably. | M3.3.2 |
| LGP-9 | File store removes retained entries. | M3.3.2 |

## Recoverable Visibility

| ID | Requirement | Target |
| --- | --- | --- |
| LGP-10 | Recoverable visibility is the durability boundary. | M3.3.0 |
| LGP-11 | Successful admission extends accepted ordering. | M3.3.0 |
| LGP-12 | Flush contract follows `FileFormatSpec.md`. | M3.3.0 |
| LGP-13 | Rejected envelopes never mutate recoverable visibility. | M3.3.0 |
| LGP-14 | Bytes beyond the recoverable prefix are non-authoritative for replay/export. | M3.3.0 |
| LGP-15 | Undefined suffix bytes never enter recoverable visibility. | M3.3.0 |
| LGP-16 | Only trailing final-line truncation is recoverable. | M3.3.2 |
| LGP-17 | Interior corruption is a hard-stop. | M3.3.2 |
| LGP-18 | Recovery discovery starts at byte zero. | M3.3.2 |
| LGP-19 | Cancellation creates no accepted bytes or accepted ordering changes. | M3.3.0 |

## Canonical Bytes And Validation

| ID | Requirement | Target |
| --- | --- | --- |
| LGP-20 | Canonical key ordering is recursive and insertion-order independent. | M3.3.0 |
| LGP-21 | The package owns canonical bytes. | M3.3.0 |
| LGP-22 | Line-size validation uses UTF-8 byte size. | M3.3.0 |
| LGP-23 | Persistence performs no Unicode normalization. | M3.3.0 |
| LGP-24 | Rejected envelopes do not mutate storage. | M3.3.0 |
| LGP-25 | Admission is the storage mutation boundary. | M3.3.0 |
| LGP-26 | LF delimiter ownership is append-local. | M3.3.0 |
| LGP-27 | Accepted bytes, including delimiters, are preserved byte-for-byte. | M3.3.0 |
| LGP-28 | Payload opacity follows `FileFormatSpec.md`. | M3.3.0 |
| LGP-29 | Canonical UUID spelling is a compatibility contract. | M3.3.0 |

## Replay, Export, And Parser Governance

### Content-Type Compatibility

| ID | Requirement | Target |
| --- | --- | --- |
| LGP-30 | Unknown `contentType` versions stay opaque. | M3.3.2 |

### Replay And Export Identity

| ID | Requirement | Target |
| --- | --- | --- |
| LGP-31 | Replay identity follows `FileFormatSpec.md`. | M3.3.0 |
| LGP-32 | Byte-stable export follows `FileFormatSpec.md`. | M3.3.2 |

### Parser Governance

| ID | Requirement | Target |
| --- | --- | --- |
| LGP-33 | Approved parser profiles produce corpus-equivalent results. | M3.3.2 |
| LGP-34 | Corpus defines duplicate-member rejection. | M3.3.2 |

### Corruption Governance

| ID | Requirement | Target |
| --- | --- | --- |
| LGP-35 | Corpus defines corruption classifications. | M3.3.2 |
| LGP-36 | Corpus defines recovery boundaries. | M3.3.2 |
| LGP-37 | Corpus defines hard-stop outcomes. | M3.3.2 |

### Validation Governance

| ID | Requirement | Target |
| --- | --- | --- |
| LGP-38 | Validation precedence is a compatibility contract. | M3.3.0 |

## Rotation Compatibility

| ID | Requirement | Target |
| --- | --- | --- |
| LGP-39 | Rotation preserves append cardinality and is not replay-visible. | M3.3.1 |

## Notes

- **Core API.** See `Decisions/0004-ordering-model.md`,
  `Decisions/0005-failure-model.md`, and
  `Decisions/0002-envelope-storage.md`.
- **File store lifecycle.** Current export, remove, and retention
  details live in `APIDesign.md`; `ExportAndRemoveDesign.md` tracks
  non-normative export/remove/retention design notes
  (count-, byte-, and age-based retention shipped).
- **Recoverable prefix / accepted bytes / replay identity.** The
  normative contract lives in `FileFormatSpec.md`.
- **Parser and corpus governance.** Corpus categories live in
  `FileFormatSpec.md`; detailed fixture candidates live in
  `CorpusSpec.md`.
