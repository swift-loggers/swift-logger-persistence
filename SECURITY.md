# Security Policy

## Supported Versions

Security fixes are provided for the latest `0.1.x` release line.
Unreleased `main` branch commits are not a supported distribution
channel for production consumers.

## Reporting A Vulnerability

Report suspected vulnerabilities through GitHub private vulnerability
reporting for this repository. Do not open a public issue or public
pull request with exploit details.

Reports should include:

- affected package version or commit,
- platform and Swift toolchain version,
- minimal reproduction steps,
- whether the issue can expose, corrupt, delete, or reorder accepted
  log bytes within recoverable visibility,
- whether the issue can leak redacted, private, or sensitive log
  values.

The persistence package does not perform network delivery and does
not manage credential storage semantics. Its security-sensitive
boundaries are local filesystem integrity, accepted-byte persistence,
export/remove correctness, parser-profile and corpus governance, and
package-provided redaction before envelope persistence:
`LogRecordPersistentEncoder` owns package-provided redaction before
envelope persistence; caller-supplied `PersistentLogEnvelope` payload
redaction is application-owned.

## Security Non-Goals And Limitations

This package does not provide tamper-evident storage. It does not
compute hash chains, signatures, MACs, or append manifests, and it
does not detect rollback, replay, or out-of-band replacement by an
actor with filesystem write access.

This package does not provide encryption-at-rest. Applications that
require encrypted log storage must provide encryption outside this
package.

Disk-full, quota, permission, and storage-stack failures are treated
as availability or persistence failures surfaced through the public
error model. They are not a guarantee that all previously accepted
bytes remain recoverable after arbitrary operating-system,
filesystem, or hardware failure.

## Dependency And Release Hygiene

Consumers should depend on released SemVer tags, not `main`, branch
requirements, or revision pins. The pre-1.0 supported requirement is:

```text
.package(
    url: "https://github.com/swift-loggers/swift-logger-persistence.git",
    .upToNextMinor(from: "0.1.0")
)
```
