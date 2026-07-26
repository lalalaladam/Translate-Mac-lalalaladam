# Standard Release Workflow

For every stable release (for example **v1.3.16**), follow the complete
workflow below. Do not skip, reorder, or silently ignore any step.

## Release Principle

-   Debug builds and Release builds follow different rules.
-   Debug builds prioritize rapid iteration and complete traceability.
-   Release builds must represent a clean, reproducible source state.
-   Never publish a Debug build as an official release.

## Part 1: Prepare Clean Release Source State

Before creating any Release build:

1.  Confirm all intended source changes are complete.
2.  Ensure the working tree is clean:

``` bash
git status
```

The result must show no uncommitted changes.

3.  Verify the source state:

``` bash
git rev-parse HEAD
git rev-list --count HEAD
```

Release builds must never contain:

    Status: dirty

The embedded build metadata must correspond exactly to the committed Git
state.

## Part 2: Build and Package

1.  Build using the **Release** configuration.

    -   Never publish a Debug build.
    -   Never use files from `Build/Products/Debug`.

2.  Perform a **Clean Build Folder** before generating the release
    package.

3.  Prefer generating an **Xcode Archive** (`.xcarchive`) instead of
    copying the app from a temporary build directory.

4.  Export the final `Translate.app` from the archive.

5.  Verify the application bundle:

``` bash
codesign --verify --deep --strict "Translate.app"
```

If verification fails, stop immediately and explain the reason. Do not
continue.

6.  Package the app using the native macOS `ditto` command:

``` bash
ditto -c -k --keepParent "Translate.app" "Translate-v1.3.16.zip"
```

Rules:

-   Do not use third-party compression software.
-   Do not upload a raw `.app` bundle.

7.  Generate a SHA-256 checksum:

``` bash
shasum -a 256 "Translate-v1.3.16.zip" > "Translate-v1.3.16.sha256"
```

Final release artifacts:

-   `Translate-v1.3.16.zip`
-   `Translate-v1.3.16.sha256`

This project does **not** have a paid Apple Developer Program
membership.

Do not attempt: - Developer ID signing - Apple Notarization - Stapling

Generate the best possible unsigned Release package following standard
macOS practices.

## Part 3: Git Workflow

After the release package has been generated and verified:

1.  Confirm the repository status is still clean:

``` bash
git status
```

2.  Confirm the current commit used for the release:

``` bash
git rev-parse HEAD
```

3.  If source changes are required after verification, stop and repeat
    the Release build process.

4.  Commit only when the release source state is final:

``` bash
git add .
git commit -m "v1.3.16"
```

5.  Push to the main branch:

``` bash
git push origin main
```

6.  Create the version tag:

``` bash
git tag v1.3.16
```

7.  Push the tag:

``` bash
git push origin v1.3.16
```

## Part 4: GitHub Release

Create a GitHub Release using tag:

`v1.3.16`

Upload only:

-   `Translate-v1.3.16.zip`
-   `Translate-v1.3.16.sha256`

Do not upload the raw `.app`.

## Part 5: Final Verification

Before considering the release complete, verify:

-   `git status` shows a clean working tree.
-   The release commit has been pushed to `origin/main`.
-   The version tag exists locally.
-   The version tag has been pushed to GitHub.
-   The GitHub Release uses the correct tag.
-   The GitHub Release contains the correct ZIP package.
-   The GitHub Release contains the SHA-256 checksum file.

If any step fails, stop immediately and explain the reason.

Do not silently skip failed steps. Do not continue after a failed step
without confirmation.

## Safety Rules

Unless explicitly requested otherwise:

-   Do not use `git push --force`
-   Do not use `git reset --hard`
-   Do not use `git rebase`
-   Do not rewrite Git history
-   Do not delete existing tags
-   Do not overwrite an existing GitHub Release
-   Do not skip verification steps
-   Do not automatically work around failed steps

Always report the exact error and wait for confirmation before
continuing.
