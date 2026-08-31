# CodexMeter V1 – Architektur

## Datenfluss

```text
OpenAI Device Login + Usage HTTPS ───────┐
                                         │  Direktmodus
1–3 isolierte Codex Homes                │
        │  codex app-server / JSONL      │
        ▼                                │
lokale Node-Bridge ──────────────────────┤  Bridge-Fallback
        │  sanitisiertes HTTP/JSON       │
        ▼                                ▼
iPhone Companion App
        ├── iPhone-App-Group ──► iPhone WidgetKit
        │                        systemSmall / systemMedium
        │                        accessoryRectangular
        │
        └── Snapshot + deduplizierbare Reset-Events
            WCSession.updateApplicationContext
            + deduplizierter User-Info-Fallback
            + Komplikations-Fast-Path im Systembudget
                    ▼
            Watch App → lokale Reset-Benachrichtigung
                    │  Watch-App-Group
                    ▼
            Watch WidgetKit → accessoryRectangular
```

Der App-Group-Container synchronisiert nicht zwischen iPhone und Watch. Auf dem
iPhone teilt er den Snapshot zwischen Companion-App und iPhone-Widget; auf der
Uhr zwischen Watch-App und Watch-Widget. Den Gerätewechsel übernimmt
WatchConnectivity.

Die gewählte Datenquelle und die Quelle des letzten iPhone-Snapshots werden
getrennt markiert. Ein Cache ohne passenden Marker wird beim Start nicht als
Reset-Baseline verwendet. Beim Umschalten wird zuerst ein leerer Snapshot an
Widgets und Watch verteilt; Sitzungen der jeweils anderen Quelle werden dabei
nicht gelöscht.

## Targets und Pakete

| Baustein | Aufgabe |
| --- | --- |
| `WatchOverlay` | iPhone-Setup, Direct-/Bridge-Abruf, Keychain, Benachrichtigungen, Watch-Sync |
| `WatchOverlayPhoneWidget` | iPhone-Homescreen- und Sperrbildschirm-Widgets aus dem App-Group-Cache |
| `WatchOverlayWatch` | Watch-App, Empfang und Persistenz des letzten Snapshots |
| `WatchOverlayWidget` | breite WidgetKit-Komplikation und Timeline |
| `UsageCore` | sanitisiertes Modell, Schwellwerte, Countdown, Reset-Erkennung |
| `WatchUI` | gemeinsame Watch-/iPhone-Widget-Layouts und QA-Renderer |
| `bridge` | 1–3 isolierte Codex-App-Server-Prozesse und lokaler HTTP-Endpunkt |

## Sanitisiertes Snapshotformat

Die Watch erhält in beiden Modi nur die technischen Slotnamen A/B/C und
Limitdaten. Upstream-E-Mail-Adressen, ChatGPT-Account-IDs,
Authentifizierungsdaten, Tokens und rohe Antworten werden nicht in das
Snapshotformat übernommen. Im Direktmodus bleiben die drei getrennten Sitzungen
im iPhone-Schlüsselbund; im Bridge-Modus bleiben sie auf dem Mac.

```json
{
  "schemaVersion": 1,
  "generatedAt": "2030-01-15T08:00:00.000Z",
  "accounts": [
    {
      "id": "account-a",
      "displayName": "A",
      "remainingPercent": 68,
      "usedPercent": 32,
      "resetsAt": "2030-01-15T09:42:00.000Z",
      "windowDurationMinutes": 300,
      "windowLabel": "5h",
      "resetCredits": 0,
      "stale": false,
      "serviceBrand": "codex"
    }
  ]
}
```

`serviceBrand` ist optionale, vom iPhone verwaltete Darstellungsmetadaten. Die
Datenquelle muss das Feld nicht liefern; die Companion-App legt die pro Account-ID
gespeicherte Auswahl über den frisch geladenen Snapshot, bevor derselbe Stand in
den iPhone-Widget-Cache geschrieben und an die Watch gesendet wird. Fehlt die
Auswahl oder ist ein zukünftiger Wert unbekannt, zeigt die UI weiter das kurze
Account-Kürzel. Die Auswahl Codex, Hermes, OpenClaw oder Buzz ändert keine
Datenquelle und enthält keine Zugangsdaten.

## Reset-Erkennung

Ein Quota-Reset gilt erst als bestätigt, wenn verbleibende Nutzung steigt,
verbrauchte Nutzung fällt, die Reset-Deadline nach hinten springt und der neue
Snapshot am alten Reset-Zeitpunkt liegt. Veraltete, doppelte oder rückwärts
datierte Samples lösen nichts aus. Ein Anstieg von `resetCredits` wird als
separates Ereignis erkannt.

Die iPhone-App zeigt bestätigte Ereignisse lokal an und überträgt dieselben
flachen `ResetEvent`-Datensätze gemeinsam mit dem Snapshot zur Watch. Die Watch
akzeptiert nur Ereignisse für Accounts des empfangenen Snapshots und dedupliziert
sie dauerhaft nach Ereignisart, Account und Erkennungszeitpunkt.

Bevor der neue Snapshot die Erkennungs-Baseline fortschreibt, werden Reset-Events
atomar in getrennten Outboxes für iPhone-Hinweis und Watch-Transport gespeichert.
Ihre stabile ID basiert auf dem tatsächlichen Reset-Zyklus beziehungsweise dem
Credit-Übergang und nicht auf dem Abrufzeitpunkt. Ein Watch-Event wird erst nach
dem erfolgreichen Completion-Callback aus der Transport-Outbox entfernt. Auf der
Watch landet es synchron im Empfangs-Callback in einer eigenen App-Group-Inbox,
bevor die asynchrone Notification-Verarbeitung startet. Dadurch überstehen
bestätigte Ereignisse Transferfehler, Neustarts und kurze Unterbrechungen;
verspätete Pakete dürfen zugleich keinen neueren Watch-Snapshot überschreiben.

Der sichtbare Countdown ist kein eigener Netzwerkabruf: Beide Widget-Extensions
nutzen denselben getesteten Zeitplan mit Fünf-Minuten-Schritten und innerhalb der
letzten 30 Minuten minütlichen Einträgen. Sowohl Watch-Komplikation als auch
iPhone-Widget lesen ihren jeweiligen App-Group-Cache spätestens nach fünf
Minuten erneut.

Für neue Netzwerkdaten registriert das iPhone beim Prozessstart den
`BGAppRefreshTask` `com.example.codexmeter.refresh`. Beim Wechsel in den
Hintergrund und nach jedem ausgeführten Hintergrundtask wird genau eine neue
Anfrage mit einem frühesten Start nach 15 Minuten geplant. Der Task nutzt
dieselbe serialisierte Refreshlogik wie die aktive App, schreibt bei Erfolg den
sanitisierten Snapshot atomar in den iPhone-Cache, fordert WidgetKit-Reloads an
und übergibt Snapshot sowie Reset-Ereignisse an WatchConnectivity. Bei Ablauf
des vom System gewährten Zeitfensters wird der Netzwerk-Task abgebrochen und als
nicht erfolgreich beendet.

Der Termin ist nur eine früheste Systemanfrage. iOS kann Hintergrundläufe und
Widget-Reloads zusammenlegen, verspäten oder auslassen. Ein frischer
Netzwerk-Snapshot entsteht daher ausschließlich nach einem tatsächlich
ausgeführten iPhone-Abruf; auf die Watch gelangt er anschließend per
WatchConnectivity.

Jeder erfolgreich abgerufene Snapshot ersetzt weiterhin den letzten
`applicationContext`. Ändert sich eine auf der Uhr sichtbare Zahl, Deadline oder
Marke, nutzt das iPhone bei verfügbarem Komplikationsbudget zusätzlich den
priorisierten Fast-Path. Ist dieses Budget leer oder die Komplikation für
WatchConnectivity nicht als aktiv gemeldet, wird derselbe sanitisierte Snapshot
als regulärer `transferUserInfo`-Hintergrundtransfer eingereiht. Von reinen
Snapshot-Transfers bleibt höchstens der neueste ausstehend; Transfers mit
Reset-Ereignissen werden nicht abgebrochen. Nach Empfang schreibt die Watch den
Snapshot atomar in ihre App Group und fordert sofort eine neue Widget-Timeline
an. Auch dieser Pfad bleibt systemgesteuert und ist keine minutengenaue
Zustellgarantie.

V1 beobachtet dafür das von der aktiven Datenquelle abgeleitete knappste Fenster. Eine
vollständige Benachrichtigung über jedes einzelne Codex-Fenster wäre eine spätere
Erweiterung des Snapshotformats.

## Sicherheitsgrenzen

Im Direktmodus nutzt die App den offiziellen OpenAI-Gerätecode-Ablauf. Sie
speichert pro Slot ein eigenes Tokenpaket als Generic-Password-Eintrag mit
`AfterFirstUnlockThisDeviceOnly`. Refresh-Tokens werden vor dem nächsten Abruf
atomar rotiert; Account-ID und Token desselben Slots werden nie kombiniert mit
einem anderen Slot. Nur HTTPS-Ziele aus der fest eingebauten OpenAI-/ChatGPT-
Konfiguration werden verwendet, Weiterleitungen werden abgelehnt. Der direkte
Usage-Endpunkt ist eine interne Codex-Schnittstelle und keine zugesicherte
öffentliche API; die Bridge bleibt deshalb als Fallback erhalten.

Für die lokale Bridge gilt zusätzlich:

Loopback funktioniert ohne Token. Unverschlüsseltes HTTP zu einem anderen Host
akzeptiert die iPhone-App nur für exakt geparste private IPv4-Adressen oder
`.local`-Namen und nur mit Bearer-Token. HTTP verschlüsselt weder diesen Token
noch die Nutzungsmetadaten; für nicht vollständig vertrauenswürdige Netze ist TLS
oder ein privater Tunnel erforderlich.
