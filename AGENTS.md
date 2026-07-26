# AGENTS.md --- Development & Build Guidelines

## Code Modification

-   Read and understand the existing architecture before modifying code.
-   Modify only files required for the task.
-   Maintain macOS compatibility.
-   Build and test locally before committing.
-   Never remove existing features unless explicitly requested.

## Release & Versioning

-   The highest published GitHub Release tag is the official version
    baseline.
-   Never use official release versions for local testing.
-   Do not commit, push, tag, or create releases without user
    authorization.

Before release, verify:

-   `git status`
-   `git rev-parse HEAD`
-   `git rev-list --count HEAD`
-   Version consistency across source, archive, tag, and release

## Build Traceability

### Official Release

Use clean public versioning:

    Version X.Y.Z (Build N)

Where:

    N = total Git commit count

Rules:

-   Build Number must remain numeric for macOS/Xcode compatibility.
-   Do not put Git hash or timestamp into CFBundleVersion.
-   Public release UI should not display debug trace metadata.

### Local Debug Build

Debug builds require full traceability.

The application must contain:

-   Marketing version
-   Numeric build number
-   Git commit hash
-   Git working tree status
-   Build timestamp

Example:

    Version: v1.0.14
    Build: 31
    Commit: 213a61a
    Status: dirty
    Build Time: 20260726.002044

Rules:

-   Git hash and timestamp must be stored as separate metadata fields.
-   They must not replace or modify the numeric Build Number.
-   Debug output folders may use:

```{=html}
<!-- -->
```
    Debug-31-213a61a-20260726.002044

-   This naming format is only for file organization and traceability.

## Git Status Rules for Debug Builds

-   `Commit` represents the Git HEAD commit used as the base source
    state for compilation.
-   If the build is generated from a working tree with uncommitted
    source changes, display:

```{=html}
<!-- -->
```
    Status: dirty

-   If the build is generated from a clean committed state, display:

```{=html}
<!-- -->
```
    Status: clean

-   Never present a build created from modified source files as a clean
    commit build.

A Debug build may represent:

    Git commit + uncommitted modifications

Therefore, the commit hash alone is insufficient to describe the exact
source state.

The Status field must clarify whether the build exactly matches the
commit.

## About Window Layout

Keep the standard macOS About window structure:

1.  Application icon
2.  Application name
3.  Standard version line:

```{=html}
<!-- -->
```
    Version X.Y.Z (Build N)

4.  Debug metadata section (Debug builds only):

```{=html}
<!-- -->
```
    Version: vX.Y.Z
    Build: N
    Commit: <hash>
    Status: <clean/dirty>
    Build Time: <timestamp>

5.  Attribution / Credits section

Keep permanent project information, including:

-   GitHub information
-   Original author attribution
-   Original project information
-   License or acknowledgement information

Rules:

-   Official releases hide only the Debug metadata section.
-   Official releases must keep Attribution / Credits information.
-   Never remove copyright, author attribution, or open-source
    acknowledgement information.

## Runtime Identification

-   Application logs must identify the exact build that generated them.
-   Debug logs should include:
    -   Marketing version
    -   Build number
    -   Git commit hash
    -   Git working tree status
    -   Build timestamp
-   Build metadata must be generated automatically during build.
-   Do not rely on manually edited version strings.

## Recommended Development Workflow

For local Debug development:

1.  Modify code.
2.  Build and test the Debug version.
3.  If the result is acceptable, commit the changes.
4.  Future clean builds should display the new commit hash with:

```{=html}
<!-- -->
```
    Status: clean

This workflow allows rapid local iteration while preserving reliable
source traceability.

## Core Principle

Production builds prioritize clean public versioning.

Debug builds prioritize complete traceability.

Never mix debug metadata with official release version numbers.

## Release Workflow

For official releases, follow:
`STANDARD_RELEASE_WORKFLOW.md`
