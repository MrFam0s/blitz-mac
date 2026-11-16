# Interface languages

Blitz Neo supports German and English. **Settings → General → Language** offers
Automatic (macOS), Deutsch and English. Automatic follows the ordered macOS
language preferences and uses the first supported language; if neither language
is listed, it falls back to English. Regional variants such as `de-CH` and
`en-GB` select the corresponding interface language.

A changed selection applies on the next app launch. Switching the setting does
not restart Blitz, reconstruct views, or interrupt terminal sessions. Blitz's
`BlitzInterfaceLanguage` preference and, for an explicit choice, `AppleLanguages`
are written only to its own app preference domain. Returning to Automatic removes
that app-specific `AppleLanguages` override. Global macOS preferences and other
apps are not changed. Native menus and file panels use the same language after
relaunch. macOS also provides per-app language settings; see
[Apple's language settings guide](https://support.apple.com/guide/mac-help/change-the-system-language-mh26684/mac).

The interface setting does not choose the language of an App Store listing.
Store localizations, descriptions, release notes, app identities, tester data,
terminal output, and responses from Apple remain in their original language.
Unknown Apple status values retain their exact original value.

## Maintaining translations

Use `L10n.tr("German source text")` for system-owned UI copy, including hints,
accessibility labels and locally generated error descriptions. Swift string
interpolation is supported: `L10n.tr("Version \(version)")` has the catalog key
`Version {0}`. Each interpolation is inserted once as data; it is never treated
as another translation key or a format string. Keep sentences intact so that
translations can reorder placeholders. Do not pass user-authored text or stable
protocol identifiers through the translator.

The `Interface`, `Release`, `Features` and `Runtime` tables in
`src/resources/{de,en}.lproj` contain explicit German and English values.
`L10n.tables` defines their lookup order. Shared keys must have identical
translations across tables. Keep Apple enum tags, stable field keys and stored
navigation identifiers unchanged; translate their presentation values only.
Display dictionaries can use `[String: L10n.Message]` and translate the selected
value with `.map(L10n.tr)`, avoiding eager translation of every status label.

The catalogs use UTF-8 `.strings` files with quoted, JSON-compatible escapes.
Preserve every numbered placeholder (`{0}`, `{1}`, …) with the same occurrence
count in both languages. Main-bundle `InfoPlist.strings` localizes macOS permission
explanations separately; keep both languages in the bundle script's declared
localizations. Use `L10n.locale` for presentation-only Foundation date/number
formatters. API date serialization must retain its required fixed format.

Run the source/catalog audit before the Swift suite:

```bash
python3 scripts/check-localization.py --self-test
swift test --build-system native --jobs 4
```

The audit lexes explicit `L10n.tr` string literals and typed display-dictionary
values, including nested interpolation and Swift multiline indentation. It
checks catalog coverage, duplicate keys, shared-translation consistency and
DE/EN placeholder parity. It fails on unsupported syntax rather than guessing;
it is not a replacement for the Swift compiler or an audit of unmarked UI copy.
For new text, check the actual rendered view in both languages, especially narrow
app panes beside the terminal. Tests can select a deterministic language with
`L10n.$overrideLanguage.withValue("de")` or `"en"` without changing preferences.
