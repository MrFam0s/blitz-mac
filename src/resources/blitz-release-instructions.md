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
- **Vorschauvideos und Poster:** Nutze im Blitz-MCP `store_previews_list`,
  `store_preview_upload` und `store_preview_set_poster` je Sprache und Gerät.
  Lies Apples Verarbeitungsstand und Posterzeit zurück. Setze ein fehlendes
  Poster am vorhandenen Video.
- **Vertriebsländer:** Prüfe mit `store_availability_get` den vollständigen
  Länderkatalog. Für beauftragte Änderungen nutze `store_availability_set`.
  Die Auswahl heutiger Länder und die Einstellung für künftig hinzukommende
  Länder sind getrennte Entscheidungen.
- **China-Erklärungen:** Lies mit `store_china_declarations_get` Anbieter,
  Anforderungs-IDs und Formulare. Speichere belegte, beauftragte Antworten mit
  `store_china_declaration_set` und lies den Stand zurück. Der Abschnitt
  „China mainland“ im Skill enthält die erforderlichen Produkt- und Dateinachweise.
- **Storetexte, neue Sprachen und Altersfreigabe:** Nutze die mitgelieferte
  `~/.blitz/bin/asc`. Prüfe Textänderungen per Dry Run und lies die gespeicherten
  Angaben bei Apple zurück. Für den Zugriff gelten die Anweisungen unter
  „Store changes through Blitz Neo“ im Skill `blitz-release`.
- Bei einem vorhandenen Release übergib den spezialisierten MCP-Werkzeugen
  die ursprüngliche `operationId` und den `accountKey`. Kläre einen ungewissen
  Sendeausgang zuerst mit `release_status`. Prüfe nach den Änderungen dieselbe
  Version und denselben Build mit `release_validate` oder der Release-CLI.
  Benötigt ein CLI-Befehl Netzwerkzugriff, fordere ihn für genau diesen Befehl an.
  Beachte eine verweigerte Berechtigung für die jeweilige Aktion.
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
