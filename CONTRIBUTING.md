# Contributing

Thanks for considering a contribution.

## Before opening a PR

1. Rebase on the latest `main` and keep changes focused.
2. Run:

   ```sh
   swift build
   swift run SelfTest
   sh scripts/build.sh
   ```

3. Include reproduction steps for behavior changes.
4. Update `README.md` and `CHANGELOG.md` when adding a user-visible feature, shortcut, setting, URL command, or release behavior.

## Code style

- Keep pure logic in `ChatGPTBarKit`; avoid adding AppKit or WebKit dependencies there.
- Keep AppKit / WebKit integration in `ChatGPTBar`.
- Prefer explicit failure messages over silent fallbacks.
- Avoid retaining `self` strongly in AppKit callbacks.

## UI changes

- Include before / after screenshots for visible UI changes.
- Test both light and dark appearance where possible.
- Mention whether the change was manually tested with an active ChatGPT login.

## Commit messages

Use short, imperative subjects, for example:

```text
Fix duplicate panel shortcut dispatch
Add tagged release workflow
```
