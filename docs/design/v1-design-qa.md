# V1 Design-QA

## iPhone-Widgets

![iPhone-Widget-Ausgabe](v1-phone-widget-preview.png)

Die Vorschau rendert dieselbe `WatchUI`-Komponente wie die iPhone-Widget-
Extension. Geprüft werden `systemSmall` mit einem und drei Accounts,
`systemMedium` mit einem bis drei Accounts sowie der monochrome
`accessoryRectangular`-Sperrbildschirm. Im kleinen Widget stehen mehrere Accounts
zugunsten der Lesbarkeit zeilenweise; im mittleren und im rechteckigen Widget
bleiben sie gleich breit nebeneinander. Prozentwert und Reset-Zeit stehen in
jedem Accountblock untereinander: Kennzeichen und Countdown belegen das obere
Drittel, die große Prozentzahl die unteren zwei Drittel.

## Watch: echte Komponente

![SwiftUI-Ausgabe](v1-layout-preview.png)

Die Vorschau wird aus demselben `WatchUI`-Swift-Package gerendert, das Watch-App
und Widget Extension einbinden. Geprüfter
Slot: 170 × 64 Punkte, Zustände mit einem, zwei und drei Accounts. Je Account
stehen Kennzeichen und Reset-Zeit oben in einer Zeile; der Prozentwert nutzt den
dominanten Bereich darunter. Die Accounts selbst bleiben nebeneinander. Das
Layout berechnet Markengröße und Typografie zusätzlich aus der tatsächlich
verfügbaren Widget-Fläche; die automatische Widget-Einrückung ist deaktiviert und
durch einen bewusst kleinen Sicherheitsrand ersetzt.

## Ergebnis

- Ein Account nutzt die volle Breite; zwei und drei Accounts teilen sie gleich.
- Der Prozentwert bleibt in jeder Dichte die dominante Information.
- Logo beziehungsweise Account-Kürzel und Reset-Zeit stehen gemeinsam oben.
- Die Prozentzahl belegt darunter etwa zwei Drittel der Account-Höhe.
- 68 % nutzt die Theme-Farbe, 21 % Gelb und 7 % Rot.
- Reset-Zeit und Account-Kennzeichen bleiben ohne Auslassungszeichen sichtbar.
- Keine Balken, Ringe oder dekorativen Messanzeigen.
- Keine sichtbaren Statuswörter wie `FREI`, `KNAPP`, `KRIT` oder `ALT`; der
  Zustand wird visuell nur über die Prozentfarbe transportiert und bleibt für
  VoiceOver textuell verfügbar.
- Pro Account kann Codex, Hermes, OpenClaw oder Buzz gewählt werden; ohne
  Auswahl bleibt das kurze Account-Kürzel als neutraler Fallback erhalten.

## Verifikationsgrenze

Die generierten Vorschauen prüfen die echte SwiftUI-Komponente und ihre
Geometrie, ersetzen aber keine Prüfung auf unterstützten Geräten und
Zifferblättern. Vor einer Release-Kandidatur sind diese visuellen Checks nötig:

1. `accessoryRectangular` auf 41/42 mm und 45/46 mm prüfen.
2. Full-Color- und Tinted-Zifferblatt vergleichen.
3. Ein-, Zwei- und Drei-Account-Preview ohne Text-Clipping bestätigen.
4. Auf einer echten Watch die Ablesbarkeit bei Always-On-Dimming prüfen.
