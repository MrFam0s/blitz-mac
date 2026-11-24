---
name: blitz-project-simulator
description: Run simulator tests, inspect iOS or iPadOS app UI, and capture screenshots for a Blitz Neo project on its own device. Use for requests such as “App testen”, “UI prüfen” or “Screenshots erstellen”, including iPhone Duo.
---

# Tests und Screenshots auf dem Projektsimulator

Wähle das zum Auftrag gehörende App-Target. Native macOS-Tests und Bildschirmfotos laufen auf dem Mac. Tests ohne Gerätedestination können den üblichen Projekt-Testbefehl verwenden.

## Projektsimulator ermitteln

1. Gleiche die Projektwurzel mit dem aufgelösten Pfad aus `blitz_macos.project_list` ab. Blitz registriert importierte Projekte häufig über einen Symlink. Prüfe bei separaten Git-Worktrees die Zugehörigkeit über Git und baue den beauftragten Checkout. Wenn zwei Chats dasselbe Projektgerät verwenden, koordiniere die Nutzung vor einem neuen App-Start oder Testlauf.
2. Lies die vereinbarte Gerätezuordnung aus den Projektanweisungen, dem vorhandenen Simulator-Resolver und, falls gesetzt, `.blitz/project.json` (`simulatorUDID`). Vergleiche die UDID mit `blitz_macos.simulator_list_devices`. Bei fehlender gespeicherter UDID löse den im Projekt festgelegten Gerätenamen eindeutig im Inventar auf. Bei mehreren Projektgeräten verwende für gewöhnliche Tests den Hauptsimulator, für einen angeforderten Gerätetyp das dafür vorgesehene Projektgerät. Widersprüchliche Zuordnungen klären, bevor du ein Gerät steuerst.
3. Fehlt das vereinbarte Gerät, prüfe auch die installierten Xcode-Runtimes und nicht verfügbaren Geräte. Für den ersten Test darfst du auf einer passenden installierten Runtime einen eigenen Simulator mit dem vereinbarten Namen anlegen. Verwende bei einem neuen Projekt ohne Namenskonvention `<Projekt> <Modell>`. Halte die zurückgegebene UDID in der lokalen Projektzuordnung fest. Fehlt eine benötigte Runtime oder ist die Gerätewahl mehrdeutig, melde den konkreten Grund. Ein beliebiges gebootetes Gerät oder ein generischer Modellname ist kein Ersatz.
4. Arbeite bei parallelen Chats direkt mit der ermittelten UDID. Ein ausgeschaltetes eigenes Gerät kannst du mit `xcrun simctl bootstatus "$UDID" -b` starten. `isSelectedForProject` und `simulator_select_device` beziehen sich auf das in der Blitz-Oberfläche aktive Projekt. Die gewöhnliche Arbeit auf einem bekannten Gerät erfordert keinen Wechsel des geöffneten Projekts. Nutze die GUI-gebundene Auswahl nur zur beabsichtigten Einrichtung bei bestätigtem aktiven Projekt.

## Testen und aufnehmen

- Führe den projektspezifischen Testwrapper mit seiner dokumentierten UDID-Option aus oder prüfe, dass sein eigener Resolver genau diese UDID liefert. Für direkte Xcode-Tests verwende `-destination "platform=iOS Simulator,id=$UDID"`. Wenn eine UI-Prüfung denselben Bildschirminhalt wie MCP beobachten muss, unterbinde dafür Xcode-Testklone. Simulator-Builds lassen sich mit `xcrun simctl install "$UDID" <Pfad-zur-Simulator-App>` installieren.
- Übergib `udid` bei **jedem** Aufruf von `blitz-iphone`. Starte den gebauten Stand mit `launch_app` und seiner Bundle-ID. Prüfe das sichtbare Ziel mit `describe_screen` oder `scan_ui`, bediene die App mit `device_action` oder `device_actions` und kontrolliere das Ergebnis. Berichte Testergebnis und beobachteten UI-Zustand getrennt.
- `get_screenshot` liefert im Textteil den Pfad zum nativen PNG. Kopiere dieses Original an den vorgesehenen Projekt- oder Ausgabeort und prüfe Motiv, Ausrichtung und Pixelmaße. Das eingebettete Bild ist eine Vorschau in Touch-Koordinaten. Ein Auftrag für Screenshots allein endet bei den lokalen Bildern.

## Faltstellung auf dem iPhone Duo

Rufe `blitz_macos.simulator_set_pose` mit `projectId`, der geprüften `udid` und `pose` (`closed`, `partiallyOpen`, `open`) auf. Blitz prüft, dass dies das aktive Projekt und sein ausgewählter, laufender Duo-Simulator ist. Bei abweichender Zuordnung kläre zuerst, welches Projekt oder Gerät gemeint ist.

Blitz verwendet bevorzugt die lokal verfügbare Scharniersteuerung von AXe für genau diese UDID. Diese benötigt keine Bedienungshilfen-Freigabe für Blitz. Fehlt ein kompatibles AXe, verwendet Blitz die Faltsteuerung im Xcode Device Hub. Für diesen Weg braucht Blitz Neo die Freigabe unter „Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen“.

Bei `confirmed: true` enthält die AXe-Antwort den vom Simulator gemessenen Winkel (`degrees`) und das aktive Display (`activeDisplay`). Bei `backend: deviceHub` und `confirmed: false` wurde der Wechsel angefordert. Prüfe das sichtbare Ergebnis, bevor du die neue Stellung meldest oder weitere Eingaben sendest. Für einen Screenshot des Außen- oder Innendisplays übergib bei `get_screenshot` zusätzlich `display: outer` bzw. `display: inner`. Bei einer über AXe bestätigten Aufnahme nennt `structuredContent.display` die Rolle, Display-ID, Display-UUID und Simulator-UDID des aufgenommenen Panels. Das gilt auch in Buchstellung, wenn das App-Fenster nur einen Teil des Displays ausfüllt.
