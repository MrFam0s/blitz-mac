## App-Store-Aufträge über Blitz Neo

Diese Wege ersetzen ältere allgemeine Einreichungsanweisungen (MCP-Vorschau,
direktes `asc submit` oder direkte API). Projektspezifische Identitäten,
Versions-, Test- und Buildregeln gelten weiterhin.

- **„Update einreichen“**: Lies `.agents/skills/blitz-release/SKILL.md` und nutze
  `~/.blitz/bin/blitz-neo release --help`. Der Auftrag umfasst für diese App die
  nötige Update-Vorbereitung, Tests, den passenden Build/Upload, den belegbaren
  Changelog und die Einreichung über die Blitz-Neo-CLI. Standard ist
  `AFTER_APPROVAL`, sofern der Nutzer oder eine ausdrücklich festgelegte
  Release-Vorgabe nichts anderes bestimmt. Vorbereitete Texte/Medien und exakte
  App-, Versions- und Build-Zuordnungen bewahren. Bei unklarem Ergebnis nur den
  bestehenden Vorgang abgleichen, nicht erneut einreichen.
- **„App im App Store neu erstellen“** (auch „App im AppStore neu erstellen“):
  Lies `.agents/skills/asc-app-create-ui/SKILL.md`. Prüfe zuerst lesend, ob der
  passende App-Datensatz bereits existiert. Falls nicht, nutze das Blitz-
  Identitätsformular und den bestätigten Anlegevorgang. App-Name, exakte Release-
  Bundle-ID einschließlich Groß-/Kleinschreibung, SKU, Plattform und Sprache
  erhalten; nur fehlende oder widersprüchliche Werte klären. Bereits für diesen
  Vorgang bestätigte Werte nicht erneut bestätigen lassen. Dieser Auftrag
  erstellt nur den App-Datensatz, ohne Build-Upload, Review-Einreichung oder
  Veröffentlichung. „Neu erstellen“ bedeutet weder Löschen noch Duplizieren.

Diese Anweisungen allein starten keinen Vorgang. Maßgeblich ist der jeweilige
ausdrückliche Nutzerauftrag; „nur vorbereiten“, TestFlight und abweichende
Veröffentlichungswünsche bleiben eigenständige Aufträge. Blitz Neo muss laufen.
