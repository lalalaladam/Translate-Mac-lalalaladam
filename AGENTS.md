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
- Release builds may hide only Debug trace metadata from About.
- Permanent Attribution / Credits, including GitHub information, original
  author attribution, original project information, and license or
  acknowledgement information, must remain visible.

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

## About Window

The About window uses a custom native, non-scrollable implementation.

Before creating, modifying, debugging, or reviewing any About-window code,
read and follow:

`docs/ABOUT_WINDOW_REQUIREMENTS.md`

That document is mandatory for all About-window work and defines:

- required content, order, and permanent Attribution / Credits protection
- menu action and controller ownership
- safe construction and presentation
- absolute no-scroll requirements
- deterministic sizing and alignment
- configuration-scoped runtime verification

Do not use the system standard About panel or change the About implementation
without checking that document first.


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
