Before modifying code:
1. Read existing architecture.
2. Do not rewrite unrelated files.
3. Keep macOS compatibility.
4. Test build before committing.
5. Never remove existing features unless requested.

Release versioning:
1. Treat the highest published GitHub Release tag as the only official version baseline.
2. Never change `MARKETING_VERSION` or reserve `release/<version>/output` for a local Debug test.
3. Store local Debug builds only in `release/local-debug/v<test-version>/output`.
4. Before an official release, set `MARKETING_VERSION`, the Archive, ZIP, SHA-256, commit message, tag, and GitHub Release to the same next version.
5. Before commit, verify `git status`, `git rev-parse HEAD`, the latest published GitHub tag, and the final Release archive version.
6. Do not commit, push, tag, or create a GitHub Release without explicit user authorization.
