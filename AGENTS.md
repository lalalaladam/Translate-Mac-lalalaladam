# AGENTS.md --- Development & Build Guidelines

## Code Modification Rules

-   Read and understand the existing architecture before modifying code.
-   Only modify files required for the task; do not rewrite unrelated
    code.
-   Maintain full macOS compatibility.
-   Always build and test locally before committing.
-   Never remove existing features unless explicitly requested.

## Release & Versioning

-   The highest published GitHub Release tag is the only official
    version baseline.
-   Never change official release versions for local testing.
-   Do not commit, push, tag, or create releases without user
    authorization.
-   Before release, verify:
    -   `git status`
    -   `git rev-parse HEAD`
    -   `git rev-list --count HEAD`
    -   version consistency between source, archive, tag, and release

## Build Traceability

### Official Release

Use clean production versions:

    vX.Y.Z (Build N)

Where:

    N = total Git commit count
    git rev-list --count HEAD

Example:

    v1.3.16 (Build 428)

Official releases only use: - Version number - Git commit count

Do not include commit hash or timestamp.

### Local Debug Build

Use traceable builds:

    Debug-N-HASH-TIMESTAMP

Example:

    Debug-428-a91f3c2-20260725.153000

Includes: - Git commit count - Short commit hash - Build timestamp

Debug builds must be isolated from official release folders.

## Runtime Logging & Version Identification

-   Application logs must identify which software version generated
    them.
-   Each log session should include:
    -   Marketing version
    -   Build number
    -   Git commit hash (when available)
    -   Build timestamp (especially for Debug builds)

Example:

    Version: v1.3.16
    Build: 428
    Commit: a91f3c2
    Build Time: 20260725.153000

-   Version information should be automatically generated during build.
-   Do not rely on manually entered version strings.

## Core Principle

Production builds prioritize simplicity.

Debug builds prioritize traceability.

Never mix local debug versions with official release versions.
