# Corpus Spec

Conformance-corpus fixture plan for `swift-logger-persistence`.
`FileFormatSpec.md` defines the normative corpus categories; this file
keeps the detailed fixture candidates out of the main wire-format spec.

Fixture bytes are immutable once released within a package major
version. Fixture ordering is non-semantic and does not define
accepted ordering unless explicitly stated otherwise.

## Corruption Fixtures

### UTF-8 Corruption

- malformed UTF-8
- invalid shortest forms
- partial scalar tails
- continuation-byte truncation
- split scalars at truncated tail boundaries
- invalid bytes immediately before LF
- overlong LF encodings
- malformed continuation chains after escaped backslashes

### JSON Corruption

- malformed JSON
- non-object JSON
- empty lines
- truncated escape sequences
- duplicate commas
- trailing commas
- malformed escaped solidus / reverse solidus chains
- malformed surrogate pairs
- escaped unicode surrogate edge chains

### Delimiter Corruption

- missing newline
- invalid LF/CRLF combinations
- escaped LF and CRLF inside JSON strings
- embedded raw LF inside malformed strings
- escaped backslash-before-LF edge cases
- escaped CR adjacent to canonical LF
- mixed CR/LF delimiters inside otherwise valid lines

### Duplicate-Key Corruption

- duplicate top-level keys
- nested duplicate keys
- top-level plus nested duplicates in one object
- duplicate keys after JSON escape decoding to the same key string
- escaped and unescaped spellings that decode to the same key string
- normalization-equivalent but scalar-distinct names remain distinct

### Base64 Corruption

- malformed base64
- malformed padding
- non-canonical padding variants

### Mixed Recovery

- trailing partial line
- mixed valid/corrupt interior lines
- any additional corruption class introduced by the package
  compatibility contract

## Semantic Validation Fixtures

### Envelope Field Validation

- uppercase UUID text
- mixed lowercase/uppercase UUID text
- unhyphenated, braced, or `urn:uuid:` UUID spellings
- invalid RFC 3339 millisecond timestamp precision

## Deterministic Encoding Fixtures

### Float Canonical Spelling

- over-limit canonical and non-canonical spellings
- canonical vs non-canonical exponent forms
- malformed exponent sign spelling
- malformed canonical exponent spelling

### Key Ordering

#### Recursive Ordering

- key-order determinism
- nested-object ordering
- recursive ordering depth
- deterministic nested array/object combinations
- mixed scalar/object recursion
- mixed-depth sparse recursion

#### Empty And Sparse Objects

- empty-object / empty-array ordering
- recursive empty containers
- sparse-object ordering
- deeply nested sparse objects

#### Unicode And Escape Ordering

- pathological Unicode key ordering
- recursive Unicode escape ordering
- mixed escaped/unescaped key ordering
- escaped solidus ordering stability
- Unicode escape canonicalization stability

#### Insertion-Order Permutations

- repeated dictionary insertion-order permutations
- repeated deep recursion ordering permutations
- repeated pathological sparse recursion ordering

### Solidus Escaping

- solidus escaping compatibility requirement
