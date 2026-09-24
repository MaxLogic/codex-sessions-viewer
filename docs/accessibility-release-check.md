# Windows release accessibility check

Build the candidate with `scripts/package_release.ps1` before checking it. Record the commit, Windows version, NVDA version, and release payload hashes with the result.

## Automated external UI Automation smoke

Run in Windows PowerShell in an interactive Windows desktop session with Windows Python and the `uiautomation` package installed:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_release_filter_uia.ps1
```

The script copies `release/package` into a temporary directory, substitutes synthetic settings, uses isolated application data and empty session sources, and closes only its own process. The default timeout is 120 seconds, allowing fresh database migration to complete. It removes its temporary directory afterwards. It does not modify the packaged settings or the user's database. The window may appear; the script sends UIA Invoke actions without mouse or keyboard input.

For Project, Model, Platform, and Origin, the script requires the exact UIA name, Button role, enabled and onscreen state, an Invoke pattern that opens the menu, an invokable option that closes it, and the expected accessible value afterwards. Project and Model select their only empty-database option; Platform and Origin change to Windows only and Subagents only. Non-default project/model filtering needs the fixture and keyboard pass below. A missing element, pattern, or state change fails the script. The output includes executable and Dart payload SHA256 hashes.

This checks the external Windows accessibility provider. It does not prove keyboard operation or NVDA speech.

## Manual NVDA keyboard and speech acceptance

Use a disposable profile with synthetic sessions containing at least two projects and models, Windows and WSL sessions, and main sessions with subagents. Keep private session content out of recordings. Enable NVDA and its Speech Viewer before starting. Keep Speech Viewer unfocused while interacting; collect only the speech produced by the checked actions.

- [ ] Tab and Shift+Tab reach each filter once in a predictable order, with a visible focus indicator. Record the sequence.
- [ ] NVDA announces Project filter, Model filter, Platform filter, and Origin filter as buttons with their current values. Record the actual utterances; wording can vary by NVDA configuration.
- [ ] Enter and Space each open a focused filter's menu. Arrow keys reach options and NVDA announces their labels and checked/selected state.
- [ ] Select a different project and model. The menu closes, focus returns to the originating button, its value is announced, and the session list reflects the selection.
- [ ] Select Windows only and then WSL only in Platform. Verify the announced value and matching sessions after each change.
- [ ] Select Main sessions, All sessions, and Subagents only in Origin. Verify the announced value and corresponding rows after each change.
- [ ] Escape closes every filter menu without changing its value and returns focus to the opener. Tab continues from that filter.
- [ ] Restore All projects, All models, Windows and WSL, and Main sessions. Confirm the values and restored results.
- [ ] Repeat the keyboard pass in high contrast and at increased display scaling; focus and menu text remain visible and usable.

Record pass/fail separately for UIA, keyboard/focus, and NVDA speech. Include failing action, expected outcome, observed outcome, relevant Speech Viewer text, and candidate hashes. Leave NVDA acceptance pending until a person has heard or captured the actual speech.


