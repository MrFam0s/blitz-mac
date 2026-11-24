## App-Tests und Screenshots

Für iOS- und iPadOS-Tests, UI-Prüfungen und Screenshots verwende automatisch
den eigenen Projektsimulator über Blitz-MCP. Lies den Skill
`blitz-project-simulator` unter `.agents/skills/` oder `.claude/skills/`.
Diese plattformspezifische Zuordnung hat Vorrang vor allgemeinen Gerätebeispielen
in älteren Blitz-Regeln.
Ordne den Arbeitsordner mit `project_list` über den aufgelösten Pfad zu und
prüfe die für dieses Projekt gespeicherte Geräte-UDID. Fehlt sie, nutze den
Simulator-Resolver des Projekts oder gleiche den ausdrücklich vereinbarten
Projektsimulator-Namen eindeutig mit dem MCP-Geräteinventar ab. Den bestehenden
Test-Wrapper des Projekts mit derselben Destination verwenden. Die Auswahl
`isSelectedForProject` in `simulator_list_devices` gehört zum sichtbaren
Blitz-Projekt. Prüfe dafür zuerst `project_get_active`. Der Zustand `Booted`
allein belegt keine Projektzuordnung.

Übergib dieselbe UDID als Testdestination und bei jeder Aktion an
`blitz-iphone`, auch bei `launch_app`, `describe_screen` und `get_screenshot`.
Für die Aufnahme hat `blitz-project-simulator` Vorrang vor `asc-shots-pipeline`.
Speichere das native PNG. Für Rahmung und Nachbearbeitung kann es an
`asc-shots-pipeline` übergeben werden. Lass parallel laufende Projekte und
deren Geräte in Ruhe. Native macOS-Ziele laufen auf dem
Mac. Bei mehreren Plattformen gilt die zum Auftrag gehörende Destination.
