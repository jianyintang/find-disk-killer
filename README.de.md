<div align="center">
  <img src="docs/assets/find-disk-killer-icon.png" width="136" height="136" alt="FindDiskKiller App-Symbol">
  <h1>FindDiskKiller</h1>
  <p><strong>Erkennen Sie, welche App Ihre Festplatte dauerhaft beansprucht.</strong></p>
  <p>Festplatten-I/O, CPU, Netzwerk, Dateiaktivität und Laufwerkszustand in einem nativen macOS-Arbeitsbereich.</p>
  <p>
    <a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> ·
    <a href="README.zh-TW.md">繁體中文</a> · <a href="README.ja.md">日本語</a> ·
    <a href="README.ko.md">한국어</a> · <a href="README.de.md">Deutsch</a> ·
    <a href="README.fr.md">Français</a> · <a href="README.es.md">Español</a> ·
    <a href="README.pt-BR.md">Português (Brasil)</a> · <a href="README.ru.md">Русский</a>
  </p>
  <p><strong>macOS 14+ · Apple-Chips & Intel · Lokale Verarbeitung · 10 Oberflächensprachen</strong></p>
  <p><a href="https://github.com/jianyintang/find-disk-killer/releases/latest">Download</a> · <a href="docs/find-disk-killer-product-and-technical-plan.md">Produktmodell</a> · <a href="SUPPORT.md">Support</a> · <a href="PRIVACY.md">Datenschutz</a></p>
</div>

---

Wenn Ihr Mac warm wird und das Laufwerk dauerhaft arbeitet, erklärt eine reine
Prozessliste oft nicht die Ursache. FindDiskKiller ordnet die Untersuchung nach
Apps: anhaltende Last erkennen, die verantwortliche App finden und anschließend
CPU, Festplatten-I/O, Netzwerk, Dateien und Speichergerät im selben Kontext prüfen.

## Alles Wichtige auf einen Blick

| Bereich | Was Sie sehen |
| --- | --- |
| **App-Aktivität** | CPU, Lesen, Schreiben, Download und Upload der letzten 5 Sekunden; sortierbare Spalten mit anpassbarer Breite und native App-Symbole |
| **Zeitverlauf** | Geradlinige Kurven für 1 Minute, 15 Minuten und 1 Stunde mit exakten Werten beim Darüberfahren |
| **Prozessdetails** | Separate Fenster zum Vergleichen von CPU-, Festplatten-, Netzwerk- und Dateiinformationen |
| **Dateiaktivität** | Aktuell geöffnete Orte und Verzeichnisse, deren Änderung in den letzten 5 Minuten beobachtet wurde |
| **Dateizugriffsverfolgung** | Bei Bedarf angeforderte Lese-/Schreibmengen, 5-Sekunden-Raten, Sitzungsspitzen, aktive Dateien und verifizierte Prozesse |
| **Laufwerke** | Durchsatz physischer Geräte über verständliche Namen eingebundener Volumes, auch bei externem Speicher |
| **Laufwerkszustand** | Temperatur, Host-Schreibmenge, Verschleiß, Reserve, Betriebsdaten und Fehler, sofern macOS sie bereitstellt |
| **Menüleiste** | Aktuelle Aktivität dezent prüfen, ohne wiederholte Mitteilungen |

## Eine durchgängige Untersuchung

```text
Anhaltende Aktivität
        |
        v
Führende App  -->  CPU / Festplatte / Download / Upload
        |
        v
Geöffnete Dateien und letzte Änderungen
        |
        v
Optionale, zeitlich begrenzte Datei- oder Ordnerverfolgung
        |
        v
Physischer Durchsatz und verfügbare Zustandsdaten
```

CPU steht immer an erster Stelle. Lesen und Schreiben sowie Download und Upload
bleiben getrennt. Aktuelle Werte basieren auf den letzten fünf Sekunden. Beim
Untersuchen einer Zeile pausiert nur die visuelle Neusortierung; die Zeile bleibt
anklickbar. Prozessdetails öffnen sich in eigenen Fenstern.

## Keine vorgetäuschte Genauigkeit

- **App-Festplatten-I/O** stammt aus Prozesszählern und umfasst alle vom Prozess verwendeten Speichergeräte.
- **Gerätedurchsatz** stammt aus Zählern physischer Geräte und wird über Namen wie `Macintosh HD` oder `JianDisk` dargestellt.
- **Letzte Änderungen** bedeuten, dass macOS eine Änderung beobachtet hat; der verursachende Prozess ist damit nicht belegt.
- **Dateizugriffsverfolgung** misst Bytes, die erfolgreiche Systemaufrufe angefordert haben. Cache, APFS-Rückschreiben, Komprimierung, Copy-on-Write, Memory Mapping und Erfassungslücken führen zu anderen Werten als bei physischen oder NAND-Schreibvorgängen.
- **Laufwerkszustand** zeigt nur Felder, die macOS tatsächlich meldet. Fehlende Daten bleiben nicht verfügbar und werden nicht zu null.

FindDiskKiller behauptet nicht, jedes Byte eines Prozesses exakt einem physischen Laufwerk zuordnen zu können.

## Datenschutz und Berechtigungen

Überwachung und Analyse erfolgen lokal auf dem Mac. Die aktuelle Version enthält
keine Werbung, Telemetrie, Nutzungsanalyse oder Tracking-SDKs Dritter und lädt
weder Prozessaktivitäten noch Dateipfade, Verlauf oder Laufwerksseriennummern hoch.

Für die grundlegende Überwachung ist keine Administratorfreigabe erforderlich.
Nur wenn Sie ausdrücklich eine Datei- oder Ordnerverfolgung starten, kann macOS
die Freigabe der signierten Hintergrundkomponente verlangen. Sie darf ausschließlich
eine zeitlich begrenzte `/usr/bin/fs_usage`-Sitzung mit festen Parametern verwalten
und kann weder eine Shell noch beliebige Befehle ausführen.

Weitere Informationen: [Datenschutzrichtlinie](PRIVACY.md) und [Sicherheitsrichtlinie](SECURITY.md).

## Voraussetzungen und Installation

- macOS 14 oder neuer
- Mac mit Apple-Chip oder Intel-Prozessor
- Administratorkonto nur zum Aktivieren der bedarfsgesteuerten Dateizugriffsverfolgung

Offizielle Versionen werden als universal2-DMG mit Developer-ID-Signatur und Apple-Beglaubigung veröffentlicht.

1. Laden Sie die neueste Version unter [Releases](https://github.com/jianyintang/find-disk-killer/releases/latest) herunter.
2. Öffnen Sie das DMG und ziehen Sie FindDiskKiller in den Ordner „Programme“.
3. Starten Sie FindDiskKiller aus „Programme“.

Zu jeder offiziellen Version wird eine SHA-256-Prüfsumme veröffentlicht. Umgehen Sie Gatekeeper nicht, wenn ein Paket die Prüfung nicht besteht.

## Erstellen und Testen

```bash
git clone git@github.com:jianyintang/find-disk-killer.git
cd find-disk-killer
xcodegen generate
xcodebuild -project FindDiskKiller.xcodeproj \
  -scheme FindDiskKillerApp -configuration Release \
  -destination 'generic/platform=macOS' build
swift test
```

Signierte und beglaubigte Website-Version aus einem sauberen Commit erstellen:

```bash
make lint test
make release VERSION=1.0.0 BUILD_NUMBER=100
```

Mit `SKIP_NOTARIZATION=1` erstellte Artefakte sind ausschließlich lokale Probeläufe und dürfen nicht veröffentlicht werden.

## Dokumentation und Support

- [Produkt- und Technikplan](docs/find-disk-killer-product-and-technical-plan.md)
- [Plan für detaillierte Dateiverfolgung und SSD-Zustand](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.md)
- [Checkliste für Website-Veröffentlichungen](docs/website-release-checklist.md)
- [Support](SUPPORT.md) · [Datenschutz](PRIVACY.md) · [Sicherheit](SECURITY.md) · [Hinweise zu Drittanbietern](THIRD_PARTY_NOTICES.md)

Allgemeine Fragen gehören in [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues).
Sicherheitslücken melden Sie vertraulich über [GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new).

FindDiskKiller wird gemäß der [All Rights Reserved-Lizenz](LICENSE) des Repositorys vertrieben.
Marken Dritter dienen nur der Erkennung beobachteter Software und stellen keine Verbindung oder Empfehlung dar.
