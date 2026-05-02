# API Compatibility

Public diagnostic enums are part of the compatibility contract because
downstream remote engines, export tooling, and tests can switch on them.

## Diagnostic Enums

This policy applies to:

- `FileLogStoreError`
- `FileLogStoreOperation`
- `FileLogStoreEnvelopeValidationError`
- `PersistenceInvariantError`

## Evolution Contract

### Enum Evolution

- External switches should include an unknown/default branch.
- Cases are append-only within one package major version.
- Existing cases are not removed, renamed, or repurposed except in a
  declared source-breaking release.
- Case names, raw value spelling, associated value labels, associated
  value ordering, associated value types, case meaning, nesting
  structure, and diagnostic family ownership are compatibility
  contracts.
- For `String`-backed diagnostic enums, `rawValue` spelling is
  a compatibility contract.
- Moving, reclassifying, regrouping, changing ownership, or
  splitting/merging diagnostic cases is source-breaking.
- Classification includes validation vs corruption and append vs
  encoding invariant classes.
- Changing accepted/rejected input sets requires a declared
  compatibility decision.
- Changing validation classification requires a declared compatibility
  decision.
- Changing corruption classification requires a declared compatibility
  decision.
- New cases may be added when new diagnostics land. Release notes call
  out additions because they can break exhaustive switches.
- Diagnostic enums are non-frozen for external consumers unless a future
  release explicitly marks one as `@frozen`.

### Format-Owned Contracts

- `FileFormatSpec.md` owns replay identity, accepted bytes, accepted
  ordering, recoverable prefix discovery, and append cardinality.
- Changing replay identity, accepted bytes, accepted ordering,
  recoverable prefix discovery, or append cardinality without versioning
  is compatibility-breaking.

### Corruption Contract

- Diagnostic precedence and deterministic precedence ordering are
  compatibility contracts.
- Changing corruption classification, class merges/splits, hard-stop
  outcomes, or unversioned parser/corpus classification requires
  compatibility review. Unversioned parser/corpus classification changes
  are compatibility-breaking.
- The trailing-truncation vs interior-corruption boundary is a
  compatibility contract.
- Changing recovery boundaries or hard-stop outcomes is
  compatibility-breaking.

### Parser/Corpus Governance

- Changing the corpus-approved parser set requires compatibility
  review.
- Parser changes must preserve corpus outcomes exactly:
  - byte fixture equivalence, including delimiter bytes
  - accepted bytes byte-for-byte
  - accepted ordering
  - corruption boundaries
  - recovery outcomes

## Non-ABI Diagnostics

`FileSystemErrorContext` is a value-typed diagnostic projection of a
platform error. Its `domain`, `code`, and `description` fields are useful
for local classification and diagnostics, but they are not persisted or
exported ABI and must not drive long-term compatibility logic.

Testing guidance for platform diagnostic text lives in
`TestingGuidance.md`.
