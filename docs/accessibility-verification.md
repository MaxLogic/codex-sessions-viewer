# Accessibility Verification

Accessibility checks are part of the normal verification path for UI work.

Run the smoke and regression suite from the Flutter app directory:

```powershell
cd app
flutter test test/accessibility
```

The suite covers:

- Semantic labels for important command buttons and icon-style action menus.
- Keyboard reachability for main navigation, session table discovery, conversation index navigation, and focus-reader jumps.
- Collapsed tool-output labels that avoid exposing large tool logs by default.
- Table equivalents for usage charts.
- High-contrast focus indicator configuration.
- Guardrails against exposing an entire conversation as one large accessible node.

When adding a new UI surface, prefer a focused accessibility regression test in
`app/test/accessibility/` for any new navigation, action, chart, table, or
conversation rendering behavior.
