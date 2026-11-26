## App-Store-Aufträge über Blitz Neo

Diese Wege ersetzen ältere allgemeine Einreichungsanweisungen (MCP-Vorschau,
direktes `asc submit` oder direkte API). Projektspezifische Identitäten,
Versions-, Test- und Buildregeln gelten weiterhin.

Hat das Projekt mehrere Veröffentlichungsziele (z. B. iOS und macOS), lies zuerst
mit `~/.blitz/bin/blitz-neo release targets --request <JSON-Datei>` die Ziele für
die explizite `projectId`. Verwende die zum Auftrag gehörende `releaseTargetId`;
bei unklarer Plattform nachfragen. Die sichtbare Auswahl ist keine Freigabe für
andere Ziele. App-ID, Bundle-ID, Konto, Version und Build bleiben pro Ziel getrennt,
auch wenn beide Plattformen denselben App-Store-Datensatz verwenden. Ein einzelner
Aufruf erstellt oder veröffentlicht niemals automatisch alle Plattformen.

- **„Update einreichen“**: Lies `.agents/skills/blitz-release/SKILL.md` und nutze
  `~/.blitz/bin/blitz-neo release --help`. Der Auftrag umfasst für diese App die
  nötige Update-Vorbereitung, Tests, den passenden Build/Upload, den belegbaren
  Changelog und die Einreichung über die Blitz-Neo-CLI. Standard ist
  `AFTER_APPROVAL`, sofern der Nutzer oder eine ausdrücklich festgelegte
  Release-Vorgabe nichts anderes bestimmt. Vorbereitete Texte/Medien und exakte
  App-, Versions- und Build-Zuordnungen bewahren. Bei unklarem Ergebnis nur den
  bestehenden Vorgang abgleichen, nicht erneut einreichen. Gehören In-App-Käufe
  oder Abos zum beauftragten Release, zusätzlich den Skill `asc-iap-attach` lesen
  und ihre exakten Metadaten-Versionen samt nötiger neuer Abo-Gruppen als
  `reviewItems` in denselben Blitz-Vorgang aufnehmen. Keine automatische Auswahl
  aller offenen Produkte und keine getrennte direkte Einreichung.
- **„Erneut einreichen“ / „Prüfung fortsetzen“**: Nutze den Abschnitt zur
  Wiedervorlage im Skill `blitz-release`. Antworte nicht mit „eingereicht“, nur
  weil eine Nachricht gesendet wurde oder ein früherer Vorgang `submitted` heißt.
  Prüfe die aktuelle Übermittlung und ihre exakten Bestandteile. Korrigierte
  abgelehnte Bestandteile müssen wieder bereitgestellt und dieselbe Übermittlung
  anschließend erneut abgesendet werden. Dafür `prepare-resubmission`, `validate`
  und das bestätigte `submit` nutzen; `resolveRejectedItems: true` nur für belegbar
  korrigierte, zur Wiedervorlage autorisierte Bestandteile. Bei unklarem Ausgang
  ausschließlich den bestehenden Vorgang abgleichen.
- Wurden fehlende Antworten zur Altersfreigabe nach dem Anlegen des Entwurfs
  ergänzt, prüfe den ursprünglichen Vorgang mit `release status`. Bei
  `refreshableSubmissionId` die ausgewiesenen Antworten mit den App-Funktionen
  abgleichen, `prepare-draft-refresh` ausführen und den Vorgang erneut validieren.
  Für eine beauftragte Einreichung denselben Entwurf mit dem neuen Bestätigungswert
  fortsetzen. Die genauen Parameter stehen im Skill `blitz-release`.
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
