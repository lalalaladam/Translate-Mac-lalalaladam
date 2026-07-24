# Standard Release Workflow

For every stable release (for example **v1.3.16**), follow the complete
workflow below. Do not skip, reorder, or silently ignore any step.

## Part 1: Build and Package

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

-   Do not use third-party compression software.
-   Do not upload a raw `.app` bundle.

7.  Generate a SHA-256 checksum:

``` bash
shasum -a 256 "Translate-v1.3.16.zip" > "Translate-v1.3.16.sha256"
```

The final release artifacts must include:

-   `Translate-v1.3.16.zip`
-   `Translate-v1.3.16.sha256`

> This project does **not** have a paid Apple Developer Program
> membership.\
> Do **not** attempt Developer ID signing, Apple Notarization, or
> Stapling.\
> Generate the best possible unsigned Release package following standard
> macOS best practices.

## Part 2: Git Workflow

After the release package has been generated and verified:

1.  Check repository status:

``` bash
git status
```

2.  Stage all changes:

``` bash
git add .
```

3.  Commit using the version number only:

``` bash
git commit -m "v1.3.16"
```

4.  Push to the main branch:

``` bash
git push origin main
```

5.  Create the version tag:

``` bash
git tag v1.3.16
```

6.  Push the tag:

``` bash
git push origin v1.3.16
```

## Part 3: GitHub Release

Create a GitHub Release using tag:

`v1.3.16`

Upload only:

-   `Translate-v1.3.16.zip`
-   `Translate-v1.3.16.sha256`

Do **not** upload the raw `.app`.

## Part 4: Final Verification

Before considering the release complete, verify all of the following:

-   `git status` shows a clean working tree.
-   The latest commit has been pushed to `origin/main`.
-   The version tag exists locally.
-   The version tag has been pushed to GitHub.
-   The GitHub Release uses the correct tag.
-   The GitHub Release contains the correct ZIP package.
-   The GitHub Release contains the SHA-256 checksum file.

If any step fails, stop immediately and explain the reason.

Do not silently skip failed steps. Do not continue after a failed step
without my confirmation.

## Safety Rules

Unless I explicitly request otherwise:

-   Do not use `git push --force`
-   Do not use `git reset --hard`
-   Do not use `git rebase`
-   Do not rewrite Git history
-   Do not delete existing tags
-   Do not overwrite an existing GitHub Release
-   Do not skip verification steps
-   Do not automatically work around failed steps

Always report the exact error and wait for my confirmation before
continuing.
