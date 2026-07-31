# AGENTS.md — Development & Build Guidelines

## Code Modification

- Read and understand the existing architecture before modifying code.
- Modify only files required for the task.
- Maintain macOS compatibility.
- Build and test locally before committing.
- Never remove existing features unless explicitly requested.
- Do not perform broad architectural refactoring unless it is required for the requested task or explicitly authorized.

### Swift File and Code Growth Control

Keep both the number of Swift source files and the size of existing Swift files under control.

Rules:

- Do not create a new Swift file when the change logically belongs to an existing file.
- Before creating a new Swift file, verify that no existing file already owns the relevant responsibility.
- Create a new Swift file only for a clearly separate responsibility, reusable component, model, service, protocol, or independently testable unit.
- Do not create small or artificial single-purpose files merely to avoid editing an existing file.
- Keep the number of newly created Swift files to the minimum required for the task.
- Keep additions to existing Swift files concise and within a reasonable scope.
- Treat approximately 150 net new lines in one existing Swift file during a single task as a review threshold.
- Treat approximately 800 total lines in a Swift file as a point at which responsibility separation should be evaluated.
- These thresholds are guidance, not automatic reasons for unrelated refactoring or artificial file splitting.
- If a task must exceed either threshold, keep the change focused and explain why the additional size is necessary.

## Release & Versioning

- The highest published GitHub Release tag is the official version baseline.
- Never use an official release version number for local testing unless preparing that authorized release.
- Do not commit, push, tag, or create releases without user authorization.

Before release, verify:

- `git status`
- `git rev-parse HEAD`
- `git rev-list --count HEAD`
- Version consistency across source, archive, tag, and release

## Build Traceability

### Universal Build Number Policy

The same numeric Build Number policy applies to every application build, including:

- Debug builds
- Release builds
- Archive builds
- Local test builds
- CI-generated builds
- Official public releases

For every build:

    CFBundleVersion = total Git commit count of HEAD

Generate it using:

    git rev-list --count HEAD

Rules:

- Every build configuration must use the same automatically generated numeric Build Number.
- Debug and Release builds must not use separate Build Number calculations.
- Do not use manually assigned, arbitrary, timestamp-based, or hash-based values as `CFBundleVersion`.
- Git hashes and timestamps must be stored as separate metadata fields.
- Uncommitted working-tree changes do not change the numeric Build Number.
- Builds based on the same HEAD commit may therefore share the same Build Number.
- Their exact source state is distinguished by commit hash, working-tree status, and build timestamp.
- Never manually edit `CFBundleVersion`.

### Official Release

Use clean public versioning:

    Version X.Y.Z (Build N)

Where:

    N = the universal numeric Build Number defined above

Rules:

- Build Number must remain numeric for macOS and Xcode compatibility.
- Do not put a Git hash or timestamp into `CFBundleVersion`.
- Public release UI must not display Debug trace metadata.

### Local Debug Build

Debug builds require full traceability.

The application must contain:

- Marketing version
- Universal numeric Build Number
- Git commit hash
- Git working-tree status
- Build timestamp

Example:

    Version: v1.0.14
    Build: 31
    Commit: 213a61a
    Status: dirty
    Build Time: 20260726.002044

Rules:

- Git hash, working-tree status, and timestamp must be stored as separate metadata fields.
- They must not replace or modify the numeric Build Number.
- Debug output folders may use:

    Debug-31-213a61a-20260726.002044

- This folder naming format is only for file organization and traceability.

### Git Status Rules for Debug Builds

- `Commit` represents the Git HEAD commit used as the base source state for compilation.
- If the build is generated from a working tree with uncommitted source changes, display:

    Status: dirty

- If the build is generated from a clean committed state, display:

    Status: clean

- Never present a build created from modified source files as a clean commit build.

A Debug build may represent:

    Git commit + uncommitted modifications

Therefore, the commit hash alone is insufficient to describe the exact source state. The Status field must clarify whether the build exactly matches the commit.

## About Window Layout

Keep the standard macOS About window structure:

1. Application icon
2. Application name
3. Standard version line:

       Version X.Y.Z (Build N)

4. Debug metadata section, for Debug builds only:

       Version: vX.Y.Z
       Build: N
       Commit: <hash>
       Status: <clean/dirty>
       Build Time: <timestamp>

5. Attribution / Credits section

Keep permanent project information, including:

- GitHub information
- Original author attribution
- Original project information
- License or acknowledgement information

Rules:

- Official releases hide only the Debug metadata section.
- Official releases must keep Attribution / Credits information.
- Never remove copyright, author attribution, or open-source acknowledgement information.

### About Window Sizing and Scrolling

The About window must not contain scrollable content in any build configuration.

This applies to Debug, Release, Archive, local test, and official public builds.

Rules:

- Do not place About window content inside `ScrollView`, `NSScrollView`, or another scrollable container.
- Do not merely hide scroll indicators while leaving the content scrollable.
- The initial window size must display all visible content without vertical or horizontal scrolling.
- When Debug metadata is present, enlarge the About window to fit the additional content.
- Increase width and height proportionally so the window remains visually balanced.
- The Debug About window may be larger than the Release About window.
- Size the window using the content's intrinsic layout requirements.
- Do not solve overflow by clipping content, hiding Credits, removing attribution, or reducing text to an unreadable size.
- The application icon, application name, version information, Debug metadata when applicable, and Attribution / Credits must all be visible at the same time.

## Runtime Identification

- Application logs must identify the exact build that generated them.
- Debug logs must include:
  - Marketing version
  - Build Number
  - Git commit hash
  - Git working-tree status
  - Build timestamp
- Build metadata must be generated automatically during the build.
- Do not rely on manually edited version strings.

## Recommended Development Workflow

For local Debug development:

1. Modify code.
2. Build and test the Debug version.
3. If the result is acceptable, commit the changes.
4. Future clean builds should display the new commit hash with:

       Status: clean

This workflow allows rapid local iteration while preserving reliable source traceability.

## Core Principle

- All builds use the same numeric Git-commit-count Build Number.
- Production builds prioritize clean public presentation.
- Debug builds add complete traceability metadata.
- Never mix Debug metadata into official release version numbers.

## Release Workflow

For official releases, follow `STANDARD_RELEASE_WORKFLOW.md`.
