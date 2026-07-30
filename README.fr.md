<div align="center">
  <img src="docs/assets/find-disk-killer-icon.png" width="136" height="136" alt="Icône de l’app FindDiskKiller">
  <h1>FindDiskKiller</h1>
  <p><strong>Identifiez l’app qui sollicite votre disque en continu.</strong></p>
  <p>Les E/S disque, le processeur, le réseau, l’activité des fichiers et l’état des disques réunis dans un espace de travail macOS natif.</p>
  <p>
    <a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> ·
    <a href="README.zh-TW.md">繁體中文</a> · <a href="README.ja.md">日本語</a> ·
    <a href="README.ko.md">한국어</a> · <a href="README.de.md">Deutsch</a> ·
    <a href="README.fr.md">Français</a> · <a href="README.es.md">Español</a> ·
    <a href="README.pt-BR.md">Português (Brasil)</a> · <a href="README.ru.md">Русский</a>
  </p>
  <p><strong>macOS 14+ · Puces Apple et Intel · Traitement local · Interface en 10 langues</strong></p>
  <p><a href="https://finddiskkiller.com/fr/download/">Télécharger</a> · <a href="https://finddiskkiller.com/fr/">Site officiel</a> · <a href="docs/find-disk-killer-product-and-technical-plan.md">Modèle du produit</a> · <a href="SUPPORT.md">Assistance</a> · <a href="PRIVACY.md">Confidentialité</a></p>
</div>

---

<p align="center"><img src="docs/assets/screenshots/overview-sustained-activity.webp" width="100%" alt="Espace Aujourd’hui de FindDiskKiller montrant une activité disque soutenue, les tendances de ressources et les apps principales."></p>
<p align="center"><sub>Repérez une activité disque soutenue et les apps qui en sont à l’origine.</sub></p>

Lorsque votre Mac chauffe et que le disque reste actif, une simple liste de
processus ne suffit pas toujours à en expliquer la cause. FindDiskKiller organise
l’enquête autour des apps : repérez une charge persistante, identifiez l’app
principale, puis examinez son processeur, ses E/S disque, son réseau, ses fichiers
et son contexte de stockage au même endroit.

## Mesurer aussi l’espace des agents IA

AI Storage ne mesure les données Codex et Claude qu’après une action explicite, puis attribue l’espace identifiable à chaque thread/session, conversation principale et sous-agent récursif. Les fichiers mesurés et les estimations de base de données restent séparés ; une preuve incomplète n’est jamais présentée comme exacte.

<p align="center"><img src="docs/assets/screenshots/ai-storage-overview.webp" width="100%" alt="Vue d’ensemble AI Storage séparant les espaces de conversation, globaux et non attribués de Codex et Claude."></p>

<p align="center"><img src="docs/assets/screenshots/ai-storage-thread-details.webp" width="100%" alt="AI Storage de Codex avec activité et sous-agents par thread, plus la composition complète du stockage du thread sélectionné à droite."></p>

Choisissez une période, un projet ou des conversations, puis vérifiez l’espace immédiatement récupérable avant la suppression définitive. Codex utilise thread/delete officiel et les sessions Claude Code autonomes le SDK Agent officiel. Les éléments actifs, modifiés ou non pris en charge sont ignorés, sans écriture SQLite directe ni suppression manuelle de transcript. Claude Desktop/Cowork doit actuellement être supprimé depuis Claude Desktop.

<p align="center"><img src="docs/assets/screenshots/ai-storage-batch-cleanup.webp" width="82%" alt="Nettoyage groupé des conversations d’agents IA avec estimation de l’espace récupérable avant suppression définitive."></p>

## L’essentiel en un coup d’œil

| Espace | Ce qu’il affiche |
| --- | --- |
| **Activité des apps** | Processeur, lectures, écritures, téléchargements et téléversements sur les 5 dernières secondes ; colonnes triables et redimensionnables, icônes natives |
| **Chronologie** | Courbes en segments droits sur 1 minute, 15 minutes ou 1 heure, avec heure et valeurs précises au survol |
| **Détails du processus** | Fenêtres indépendantes pour comparer le processeur, le disque, le réseau et les fichiers d’une app |
| **Activité des fichiers** | Emplacements actuellement ouverts et dossiers dont une modification a été observée au cours des 5 dernières minutes |
| **Suivi des accès aux fichiers** | À la demande : volumes de lecture/écriture demandés, débits sur 5 secondes, pics de session, fichiers actifs et processus vérifiés |
| **Disques** | Débit des périphériques physiques présenté avec le nom lisible des volumes montés, y compris les supports externes |
| **État du disque** | Température, écritures hôte, usure, réserve, historique d’alimentation et erreurs lorsque macOS les expose |
| **Barre des menus** | Un aperçu discret de l’activité actuelle, sans notifications répétitives |

## Une vue complète, de l’app au disque

### Commencer par l’app responsable

<p align="center"><img src="docs/assets/screenshots/app-codex-overview.webp" width="100%" alt="Détails de l’app Codex avec chronologies séparées pour le processeur, les E/S disque et le réseau."></p>

### Examiner ensuite les emplacements et les accès bornés

<p align="center"><img src="docs/assets/screenshots/app-codex-file-activity.webp" width="100%" alt="Activité des fichiers de Codex montrant les emplacements associés, les dossiers accessibles en écriture et les changements récents."></p>

<p align="center"><img src="docs/assets/screenshots/folder-access-trace.webp" width="100%" alt="Suivi de dossier limité dans le temps montrant les débits demandés, les fichiers actifs et les processus qui y accèdent."></p>

### Terminer par le stockage et son état

<p align="center"><img src="docs/assets/screenshots/disk-live-activity.webp" width="100%" alt="Espace Disques montrant le débit des périphériques physiques, les volumes montés et les diagnostics matériels."></p>

<p align="center"><img src="docs/assets/screenshots/disk-health.webp" width="100%" alt="État du disque montrant le statut SMART, l’usure, la température, les écritures hôte, l’historique d’alimentation et les erreurs média."></p>

## Une enquête dans un contexte unique

```text
Activité persistante
        |
        v
App principale  -->  Processeur / disque / téléchargement / téléversement
        |
        v
Fichiers ouverts et modifications récentes
        |
        v
Suivi facultatif et limité dans le temps d’un fichier ou dossier
        |
        v
Débit physique et données de santé disponibles
```

Le processeur apparaît toujours en premier. Lecture et écriture, téléchargement
et téléversement restent séparés. Les valeurs actuelles utilisent les cinq
dernières secondes. Au survol d’une ligne, seul le réordonnancement visuel est
suspendu : la ligne reste cliquable. Les détails s’ouvrent dans leur propre fenêtre.

## Aucune fausse précision

- Les **E/S disque de l’app** proviennent des compteurs du processus et couvrent tous les supports qu’il utilise.
- Le **débit du périphérique** provient des compteurs physiques et apparaît sous des noms compréhensibles comme `Macintosh HD` ou `ExternalSSD`.
- Les **modifications récentes** signifient que macOS a observé un changement ; elles n’identifient pas à elles seules le processus responsable.
- Le **suivi des accès** mesure les octets demandés par les appels système réussis. Cache, écritures différées APFS, compression, copie sur écriture, mappage mémoire et lacunes de couverture expliquent l’écart avec les écritures physiques ou NAND.
- L’**état du disque** ne contient que les champs réellement fournis par macOS. Une valeur absente reste indisponible au lieu de devenir zéro.

FindDiskKiller ne prétend pas attribuer exactement chaque octet d’un processus à un disque physique donné.

## Confidentialité et autorisations

La surveillance et l’analyse sont effectuées localement. La version actuelle ne
contient ni publicité, ni télémétrie, ni analyse comportementale, ni SDK de suivi
tiers. Elle ne téléverse pas l’activité des processus, les chemins, l’historique
de surveillance ou les numéros de série des disques.

La surveillance de base ne demande pas de droits administrateur. macOS peut
demander l’autorisation du composant d’arrière-plan signé uniquement lorsque vous
lancez explicitement le suivi d’un fichier ou d’un dossier. Ce composant ne peut
superviser qu’une session `/usr/bin/fs_usage` limitée dans le temps et aux
paramètres fixes ; il ne peut exécuter ni shell ni commande arbitraire.

Consultez la [Politique de confidentialité](PRIVACY.md) et la [Politique de sécurité](SECURITY.md).

## Configuration requise et installation

- macOS 14 ou version ultérieure
- Mac avec puce Apple ou processeur Intel
- Compte administrateur uniquement pour activer le suivi des accès à la demande

Lorsqu'elles sont disponibles, les versions officielles sont distribuées sous forme de DMG universal2 signé avec un Developer ID et notarié par Apple.

1. Téléchargez la dernière version depuis le [site officiel](https://finddiskkiller.com/fr/download/).
2. Ouvrez le DMG et faites glisser FindDiskKiller dans Applications.
3. Lancez FindDiskKiller depuis Applications.

Chaque version officielle publie une somme SHA-256. Ne contournez jamais Gatekeeper pour un paquet qui échoue à la validation.

## Compilation et tests

Le développement nécessite Xcode 16 ou version ultérieure et XcodeGen 2.42.0 ou version ultérieure.

```bash
git clone https://github.com/jianyintang/find-disk-killer.git
cd find-disk-killer
xcodegen generate
xcodebuild -project FindDiskKiller.xcodeproj \
  -scheme FindDiskKillerApp -configuration Release \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO build
swift test
```

La build de développement non signée permet de valider la surveillance de base,
mais pas d’exécuter le suivi privilégié d’un fichier ou dossier. L’app et le
helper s’authentifient mutuellement avec le Team ID du mainteneur ; ce parcours
doit donc être vérifié avec une build officielle signée. L’approbation du
composant en arrière-plan et l’accès complet au disque pour les emplacements
protégés sont deux autorisations macOS distinctes.

Pour créer une version signée et notariée à partir d’un commit propre :

```bash
make lint test
make release VERSION=1.0.0 BUILD_NUMBER=100
```

Les artefacts produits avec `SKIP_NOTARIZATION=1` servent uniquement aux répétitions locales et ne doivent jamais être publiés.

## Documentation et assistance

- [Plan produit et technique](docs/find-disk-killer-product-and-technical-plan.md)
- [Plan de suivi approfondi des fichiers et de santé SSD](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.md)
- [Liste de contrôle de publication Web](docs/website-release-checklist.md)
- [Contribuer](CONTRIBUTING.md)
- [Assistance](SUPPORT.md) · [Confidentialité](PRIVACY.md) · [Sécurité](SECURITY.md) · [Mentions tierces](THIRD_PARTY_NOTICES.md)

Utilisez [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues) pour l’assistance courante.
Signalez une vulnérabilité en privé avec [GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new).

FindDiskKiller est un logiciel libre sous [licence MIT](LICENSE).
Les marques d’apps tierces servent uniquement à identifier les logiciels observés et n’impliquent aucune affiliation ni recommandation.
