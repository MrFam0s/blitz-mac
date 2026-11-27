## App-Store-Aufträge über Blitz Neo

Diese Wege ersetzen ältere allgemeine Einreichungsanweisungen (MCP-Vorschau,
direktes `asc submit` oder direkte API). Projektspezifische Identitäten,
Versions-, Test- und Buildregeln gelten weiterhin.

`blitz-neo release --help` und die eigenständigen `asc`-Befehle funktionieren
bei geschlossener App. Erst wenn ein Release-Befehl die lokale Verbindung
benötigt, prüft die CLI, ob Blitz Neo läuft. Sie nutzt die laufende App oder
startet sie bei Bedarf und wartet vor dem Senden auf die Verbindung.

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
- **Storetexte, neue Sprachen, Vorschauvideos, Poster und Vertriebsländer** bearbeitest
  du über die mitgelieferte `~/.blitz/bin/asc`. Lies dafür „Use the bundled CLI
  for Store changes“ im Skill `blitz-release`, auch wenn im MCP eine Aktion fehlt.
  Ist der Ausgang einer früheren Einreichung unklar, lies zuerst den Status
  des ursprünglichen Vorgangs und warte mit Store-Änderungen auf die Klärung.
  Prüfe geplante Textänderungen per Dry Run und lies das Ergebnis für die
  beauftragten Sprachen, Geräte oder Länder bei Apple zurück. Blockiert der Chat
  den App-Start, die lokale Verbindung zu Blitz Neo oder den Netzwerkzugriff auf
  Apple, fordere die passende Berechtigung für den konkreten Befehl an. Lass
  eine bereits laufende App bei gesperrter Verbindung geöffnet. Wird der Zugriff abgelehnt,
  benenne den offenen Schritt. Eine Browseranmeldung hilft bei einem von Apple
  gemeldeten Anmeldeproblem. Prüfe nach den Änderungen am Entwurf dieselbe
  Version und denselben Build erneut über Blitz.
- **Fehlende Altersfreigabe oder China-Erklärungen:** Nutze den Abschnitt
  „Correct required declarations on a prepared build“ im Skill `blitz-release`.
  Verwende die mitgelieferte `~/.blitz/bin/asc`. Lies gespeicherte Antworten bei
  Apple zurück und prüfe dieselbe Version mit derselben Build-ID über
  `~/.blitz/bin/blitz-neo release validate`. Verlangt Blitz vor dem ersten
  Einreichungsversuch wegen geänderter Angaben eine neue Vorbereitung, nutze
  dieselbe Build-Zuordnung. Bei einem bereits begonnenen Einreichungsversuch
  oder zugeordneten Apple-Prüfentwurf führt `release status` des ursprünglichen
  Vorgangs zur passenden Fortsetzung.
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
Veröffentlichungswünsche bleiben eigenständige Aufträge.

### Freigabe für das Ersetzen von Store-Galerien

Vergleiche die gewünschte Bilderfolge mit dem aktuellen Bestand im bearbeitbaren
App-Store-Entwurf. Ermittle für jede betroffene Store-Sprache und Gerätegruppe die
IDs der Entwurfsbilder, die entfallen. Bilder, die nur den Platz wechseln, bleiben erhalten.

Fehlt die Freigabe zum Entfernen, stelle eine gemeinsame Frage für Upload,
Löschung und Sortierung. Nenne App, Plattform, Entwurfsversion und je Sprache und
Gerätegruppe die Anzahl zu entfernender Bilder, ihre Gesamtsumme und die gewünschte
Reihenfolge. Setze dafür die tatsächlichen Werte aus dem Abgleich ein. Verwende
denselben Umfang in der Begründung des Werkzeugaufrufs. Hat der Nutzer diese
Ersetzung bereits ausdrücklich beauftragt, nutze die erteilte Freigabe direkt.

> Soll ich im [Plattform]-Entwurf [Version] von [App] die freigegebenen Bilder
> hochladen, die bisherigen Entwurfsbilder entfernen ([Store-Sprache und Gerät:
> Anzahl je Gruppe], insgesamt [Summe]) und die Motive in der Reihenfolge
> [Platz und Motiv je Galerie] anordnen?

Entferne nur die im Abgleich identifizierten und freigegebenen Entwurfsbilder.
Lies anschließend für jede betroffene Galerie die Bild-IDs, Plätze und
Verarbeitungsstände bei Apple aus und vergleiche sie mit der gewünschten Bilderfolge.

### Veröffentlichung in Festlandchina

Prüfe beim Store-Release für den gebundenen App-Datensatz, ob Festlandchina
(`CHN`) bei Apple ausgewählt oder im Auftrag ausdrücklich vorgesehen ist.
Ist das Gebiet nachweislich ausgeschlossen und keine Aufnahme beauftragt,
entfällt die China-Prüfung. Eine chinesische Übersetzung oder eine
Galerieänderung allein löst keine Abgabe von Erklärungen aus.

Bei Vertrieb in `CHN` folge dem Abschnitt „China mainland“ im Skill
`blitz-release`. Ermittle beide Antworten zu KI-/synthetischen Diensten und
zur Sicherheitsbewertung getrennt aus den dort angebotenen Funktionen.
Prüfe außerdem die für diese App geltenden Registrierungen und Genehmigungen.
Übernimm belegte Angaben im Umfang des China-Releaseauftrags selbstständig.
Frage gesammelt nur nach offenen Tatsachen, amtlichen Belegen oder einer noch
fehlenden Befugnis. Lies anschließend den Status jeder Erklärung bei Apple aus.
