<div align="center">
  <img src="docs/assets/find-disk-killer-icon.png" width="128" height="128" alt="FindDiskKiller App-Symbol">
  <h1>FindDiskKiller</h1>
  <p><strong>Sehen Sie, was Ihre Festplatte ständig nutzt.</strong></p>
  <p>Beginnen Sie bei der Datenträger-E/A einer App und folgen Sie den Hinweisen über Dateiaktivität, AI-Agent-Speicher und physische Laufwerke.</p>
  <p>
    <a href="README.md">English</a> ·
    <a href="README.zh-CN.md">简体中文</a> ·
    <a href="README.zh-TW.md">繁體中文</a> ·
    <a href="README.ja.md">日本語</a> ·
    <a href="README.ko.md">한국어</a> ·
    <a href="README.de.md">Deutsch</a> ·
    <a href="README.fr.md">Français</a> ·
    <a href="README.es.md">Español</a> ·
    <a href="README.pt-BR.md">Português (Brasil)</a> ·
    <a href="README.ru.md">Русский</a>
  </p>
  <p><strong>macOS 14+ · Apple Silicon & Intel · 100% lokale Verarbeitung</strong></p>
  <p>
    <a href="https://finddiskkiller.com/de/download/"><strong>Für macOS laden</strong></a> ·
    <a href="https://finddiskkiller.com/de/">Website</a> ·
    <a href="https://finddiskkiller.com/de/how-it-works/">Funktionsweise</a> ·
    <a href="PRIVACY.md">Datenschutz</a> ·
    <a href="SUPPORT.md">Support</a>
  </p>
</div>

---

<a href="docs/assets/screenshots/overview-sustained-activity.webp">
  <img src="docs/assets/screenshots/overview-sustained-activity.webp" width="100%" alt="Vollständiger FindDiskKiller-Arbeitsbereich mit anhaltender Datenträgeraktivität, Ressourcentrends und führenden Apps.">
</a>

<p align="center"><sub>Erkennen Sie anhaltende Datenträgeraktivität und die verantwortlichen Apps. Klicken Sie für das Originalbild.</sub></p>

FindDiskKiller ist ein natives macOS-Werkzeug für eine klar umrissene Aufgabe: anhaltende Datenträgeraktivität bis zu den verantwortlichen Apps, Dateien und physischen Geräten zu verfolgen. CPU-, Datenträger- und Netzwerkhinweise bleiben app-zentriert, statt über mehrere Systemwerkzeuge verteilt zu sein.

<p align="center">
  <strong>100%</strong> lokal　·　<strong>0</strong> Daten hochgeladen　·　<strong>10</strong> Sprachen　·　<strong>macOS 14+</strong>
</p>

## Alles in einem Arbeitsbereich

### AI-Agent-Speicher

Codex und Claude sammeln Unterhaltungen, Subagent-Sitzungen, Snapshots, Visualisierungen und gemeinsame Datenbanken. AI Storage startet die lokale Analyse nur nach einem ausdrücklichen Klick, ordnet Speicher einzelnen Threads oder Sitzungen zu und bietet eine vollständige Prüfung vor dem dauerhaften Löschen.

<a href="docs/assets/screenshots/ai-storage-overview.webp">
  <img src="docs/assets/screenshots/ai-storage-overview.webp" width="100%" alt="AI-Storage-Übersicht mit getrennten Chat-, globalen und nicht zugeordneten Werten für Codex und Claude.">
</a>

<p align="center"><sub>Zuerst den gesamten Anbieterspeicher messen, dann Chats, globale Daten und nicht zugeordneten Speicher trennen.</sub></p>

<p align="center">
  <a href="docs/assets/screenshots/ai-storage-thread-details.webp"><img src="docs/assets/screenshots/ai-storage-thread-details.webp" width="57%" alt="Codex AI Storage mit Aktivität, Subagents und vollständiger Aufteilung des gewählten Threads."></a>
  <a href="docs/assets/screenshots/ai-storage-batch-cleanup.webp"><img src="docs/assets/screenshots/ai-storage-batch-cleanup.webp" width="41%" alt="Stapelbereinigung mit Auswahlumfang und voraussichtlich sofort freigebbarem Speicher vor dem dauerhaften Löschen."></a>
</p>

<p align="center"><sub>Links: Speicher einer Unterhaltung zuordnen　·　Rechts: Alter, Projekt und Unterhaltungen vor dem Löschen prüfen</sub></p>

Die Analyse startet nie automatisch. Aktive oder identitätsveränderte Sitzungen werden übersprungen; nicht unterstützte Anbieter führen nie zu direkten Datenbankänderungen oder manuellem Löschen von Transkripten. Claude-Desktop- und Cowork-Sitzungen müssen derzeit in Claude Desktop gelöscht werden.

### App-Aktivität und Dateihinweise

Vergleichen Sie CPU-, Datenträger- und Netzwerkverläufe einer App und wechseln Sie dann zu geöffneten Orten und kürzlich geänderten Verzeichnissen. Bei Bedarf starten Sie ausdrücklich eine zeitlich begrenzte Datei- oder Ordnerverfolgung.

<p align="center">
  <a href="docs/assets/screenshots/app-codex-overview.webp"><img src="docs/assets/screenshots/app-codex-overview.webp" width="49%" alt="Codex-App-Details mit getrennten CPU-, Datenträger- und Netzwerkzeitachsen."></a>
  <a href="docs/assets/screenshots/app-codex-file-activity.webp"><img src="docs/assets/screenshots/app-codex-file-activity.webp" width="49%" alt="Codex-Dateiaktivität mit zugehörigen Orten, beschreibbaren Ordnern und letzten Änderungen."></a>
</p>

<p align="center"><sub>Links: anhaltende Ressourcenaktivität erkennen　·　Rechts: zu den beteiligten Orten wechseln</sub></p>

<p align="center">
  <a href="docs/assets/screenshots/folder-access-trace.webp"><img src="docs/assets/screenshots/folder-access-trace.webp" width="86%" alt="Begrenzte Ordnerverfolgung mit angeforderten Lese-/Schreibraten, aktiven Dateien und zugreifenden Prozessen."></a>
</p>

<p align="center"><sub>Die Verfolgung läuft nur nach ausdrücklichem Start und zeigt angeforderte E/A, aktive Dateien und verifizierte Prozesssitzungen.</sub></p>

### Physische Laufwerke und Zustand

Ordnen Sie bekannte Volumenamen wie Macintosh HD oder externe Laufwerke dem Durchsatz physischer Geräte zu und prüfen Sie die SMART/NVMe-Felder, die macOS und die Hardware tatsächlich bereitstellen.

<p align="center">
  <a href="docs/assets/screenshots/disk-live-activity.webp"><img src="docs/assets/screenshots/disk-live-activity.webp" width="49%" alt="Laufwerksansicht mit physischem Gerätedurchsatz, eingebundenen Volumes und Hardwarediagnose."></a>
  <a href="docs/assets/screenshots/disk-health.webp"><img src="docs/assets/screenshots/disk-health.webp" width="49%" alt="Laufwerkszustand mit SMART-Status, Verschleiß, Temperatur, Host-Schreibvorgängen, Betriebsverlauf und Medienfehlern."></a>
</p>

<p align="center"><sub>Links: das aktive physische Gerät erkennen　·　Rechts: gemeldete Zustandsinformationen prüfen</sub></p>

## Keine vorgetäuschte Genauigkeit

FindDiskKiller zeigt zusammengehörige Hinweise gemeinsam, zwingt Messungen mit unterschiedlicher Bedeutung aber nicht in eine Zahl:

- **App-E/A** meldet Prozessanforderungen über alle Speichergeräte und ist kein physischer NAND-Verkehr.
- **Gerätedurchsatz** kann keinem einzelnen Prozess exakt zugeordnet werden; App- und Gerätesummen müssen nicht übereinstimmen.
- **Kürzlich geänderte Orte** zeigen eine von macOS beobachtete Änderung, identifizieren allein aber nicht den Schreiber.
- **AI-Datenbankzuordnung** ist eine gekennzeichnete logische Schätzung, kein sofort physisch freigebbarer Speicher.

Fehlende, teilweise oder nicht unterstützte Hinweise werden als nicht verfügbar angezeigt und nicht durch Null ersetzt.

## Datenschutz und Berechtigungen

Überwachung, Analyse und Anzeige bleiben auf dem Mac. Die aktuelle Version lädt keine Prozessnamen, Dateipfade, Laufwerksseriennummern oder Überwachungsverläufe hoch und enthält keine Werbung, Telemetrie, Analyse oder Tracking-SDKs Dritter.

Die Basisüberwachung von CPU, Datenträger, Netzwerk, Volumes und Prozessen benötigt keine Administratorfreigabe. Erst beim ausdrücklichen Start einer Datei- oder Verzeichnisverfolgung kann macOS die Freigabe der signierten, zweckgebundenen Hintergrundkomponente verlangen; geschützte Orte können zusätzlich vollen Festplattenzugriff erfordern. Sie bestimmen stets Start und Ende der Verfolgung.

Lesen Sie die vollständige [Datenschutzerklärung](PRIVACY.md) · [Sicherheitsrichtlinie](SECURITY.md).

## Installation

1. Laden Sie das neueste signierte und notarisierte DMG von der [offiziellen Website](https://finddiskkiller.com/de/download/) herunter.
2. Öffnen Sie es und ziehen Sie FindDiskKiller in den Programme-Ordner.
3. Starten Sie FindDiskKiller aus Programme.

Offizielle Versionen unterstützen Apple Silicon und Intel Macs und enthalten eine SHA-256-Prüfsumme. Umgehen Sie Gatekeeper nicht, wenn Signatur- oder Notarisierungsprüfung fehlschlägt.

## Entwicklung und Dokumentation

<details>
<summary><strong>Aus dem Quellcode bauen und Tests ausführen</strong></summary>

Die Entwicklung benötigt Xcode 16+ und XcodeGen 2.42.0+.

```bash
git clone https://github.com/jianyintang/find-disk-killer.git
cd find-disk-killer
xcodegen generate
xcodebuild \
  -project FindDiskKiller.xcodeproj \
  -scheme FindDiskKillerApp \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  build
make test
```

Der unsignierte Build deckt die Basisüberwachung ab, nicht jedoch privilegiertes Dateitracing, das offiziell signierte App- und Helper-Identitäten benötigt.

</details>

- [Produkt- und Technikplan](docs/find-disk-killer-product-and-technical-plan.md)
- [Plan für tiefes Dateitracing und SSD-Zustand](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.md)
- [Website-Release-Checkliste](docs/website-release-checklist.md)
- [Mitwirken](CONTRIBUTING.md)
- [Hinweise zu Drittanbietern](THIRD_PARTY_NOTICES.md)

## Support und Lizenz

Für Fragen, Fehler und Funktionswünsche nutzen Sie [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues). Melden Sie Schwachstellen privat über [GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new) und entfernen Sie sensible Pfade, Benutzernamen und Laufwerksseriennummern aus Diagnosen oder Screenshots.

FindDiskKiller ist unter der [MIT License](LICENSE) quelloffen.
