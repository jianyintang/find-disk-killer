<div align="center">
  <img src="docs/assets/find-disk-killer-icon.png" width="128" height="128" alt="Icône de l’app FindDiskKiller">
  <h1>FindDiskKiller</h1>
  <p><strong>Voyez ce qui sollicite continuellement votre disque.</strong></p>
  <p>Partez des E/S disque des apps, puis suivez les indices à travers l’activité des fichiers, l’espace des agents IA et les disques physiques.</p>
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
  <p><strong>macOS 14+ · Apple silicon et Intel · Traitement 100 % local</strong></p>
  <p>
    <a href="https://finddiskkiller.com/fr/download/"><strong>Télécharger pour macOS</strong></a> ·
    <a href="https://finddiskkiller.com/fr/">Site officiel</a> ·
    <a href="https://finddiskkiller.com/fr/how-it-works/">Fonctionnement</a> ·
    <a href="PRIVACY.md">Confidentialité</a> · <a href="SUPPORT.md">Assistance</a>
  </p>
</div>

---

<a href="docs/assets/screenshots/overview-sustained-activity.webp">
  <img src="docs/assets/screenshots/overview-sustained-activity.webp" width="100%" alt="Espace Maintenant complet de FindDiskKiller montrant l’activité disque persistante, les tendances et les apps principales.">
</a>

<p align="center"><sub>Détectez une activité disque persistante et identifiez les apps responsables. Cliquez pour ouvrir l’image originale.</sub></p>

FindDiskKiller est un outil macOS natif centré sur une tâche : remonter d’une activité disque persistante jusqu’aux apps, fichiers et périphériques physiques qui l’expliquent. Les indices CPU, disque et réseau restent organisés autour de l’app, sans reconstituer le contexte entre plusieurs outils système.

<p align="center"><strong>100 %</strong> local　·　<strong>0</strong> donnée envoyée　·　<strong>10</strong> langues　·　<strong>macOS 14+</strong></p>

## Toutes les informations dans un seul espace

### Espace des agents IA

Codex et Claude accumulent conversations, sessions de sous-agents, instantanés, visualisations et bases partagées. AI Storage lance l’analyse locale uniquement après une action explicite, attribue l’espace à chaque thread ou session et permet une vérification complète avant la suppression définitive.

<a href="docs/assets/screenshots/ai-storage-overview.webp"><img src="docs/assets/screenshots/ai-storage-overview.webp" width="100%" alt="Vue AI Storage séparant les espaces de conversation, globaux et non attribués de Codex et Claude."></a>

<p align="center"><sub>Mesurez d’abord l’espace total du fournisseur, puis séparez conversations, données globales et espace non attribué.</sub></p>

<p align="center">
  <a href="docs/assets/screenshots/ai-storage-thread-details.webp"><img src="docs/assets/screenshots/ai-storage-thread-details.webp" width="57%" alt="AI Storage de Codex montrant l’activité, les sous-agents et la composition complète du thread sélectionné."></a>
  <a href="docs/assets/screenshots/ai-storage-batch-cleanup.webp"><img src="docs/assets/screenshots/ai-storage-batch-cleanup.webp" width="41%" alt="Nettoyage par lots montrant la sélection et l’espace immédiatement récupérable estimé avant suppression définitive."></a>
</p>

<p align="center"><sub>Gauche : attribuer l’espace à une conversation　·　Droite : vérifier âge, projet et conversations avant suppression</sub></p>

L’analyse ne démarre jamais automatiquement. Les sessions actives ou dont l’identité a changé sont ignorées ; un fournisseur non pris en charge ne provoque jamais d’écriture directe en base ni de suppression manuelle des transcripts. Les sessions Claude Desktop et Cowork se suppriment actuellement dans Claude Desktop.

### Activité des apps et indices de fichiers

Comparez les tendances CPU, disque et réseau d’une app, puis ouvrez ses emplacements actifs et répertoires récemment modifiés. Lorsque davantage de preuves sont nécessaires, démarrez explicitement un suivi de fichier ou dossier limité dans le temps.

<p align="center">
  <a href="docs/assets/screenshots/app-codex-overview.webp"><img src="docs/assets/screenshots/app-codex-overview.webp" width="49%" alt="Détail de l’app Codex avec chronologies séparées pour le CPU, les E/S disque et le réseau."></a>
  <a href="docs/assets/screenshots/app-codex-file-activity.webp"><img src="docs/assets/screenshots/app-codex-file-activity.webp" width="49%" alt="Activité des fichiers Codex montrant les emplacements associés, les dossiers inscriptibles et les changements récents."></a>
</p>

<p align="center"><sub>Gauche : vérifier si l’activité persiste　·　Droite : accéder aux emplacements concernés</sub></p>

<p align="center"><a href="docs/assets/screenshots/folder-access-trace.webp"><img src="docs/assets/screenshots/folder-access-trace.webp" width="86%" alt="Suivi de dossier limité montrant les débits demandés, les fichiers actifs et les processus qui y accèdent."></a></p>

<p align="center"><sub>Le suivi ne fonctionne qu’après un démarrage explicite et montre les E/S demandées, les fichiers actifs et les sessions de processus vérifiées.</sub></p>

### Disques physiques et état

Associez les noms familiers comme Macintosh HD ou les disques externes au débit des périphériques physiques, puis consultez les champs SMART/NVMe réellement exposés par macOS et le matériel.

<p align="center">
  <a href="docs/assets/screenshots/disk-live-activity.webp"><img src="docs/assets/screenshots/disk-live-activity.webp" width="49%" alt="Espace Disques montrant le débit des périphériques physiques, les volumes montés et les diagnostics matériels."></a>
  <a href="docs/assets/screenshots/disk-health.webp"><img src="docs/assets/screenshots/disk-health.webp" width="49%" alt="État du disque montrant SMART, usure, température, écritures hôte, historique d’alimentation et erreurs média."></a>
</p>

<p align="center"><sub>Gauche : repérer le périphérique actif　·　Droite : consulter les données de santé qu’il fournit</sub></p>

## Aucune fausse précision

FindDiskKiller réunit les indices liés sans forcer des mesures de sens différent dans un même nombre :

- **Les E/S d’app** sont des requêtes de processus sur l’ensemble du stockage, pas des accès NAND physiques.
- **Le débit du périphérique** ne peut pas être attribué exactement à un processus ; les totaux app et périphérique n’ont pas à coïncider.
- **Un emplacement récemment modifié** indique un changement observé par macOS, sans identifier seul son auteur.
- **L’attribution de base IA** est une estimation logique signalée, pas un espace physique immédiatement récupérable.

Les indices absents, partiels ou non pris en charge restent indisponibles au lieu d’être remplacés par zéro.

## Confidentialité et autorisations

Toute la surveillance, l’analyse et l’affichage restent sur le Mac. La version actuelle ne transmet ni noms de processus, ni chemins, ni numéros de série, ni historique ; elle ne contient aucune publicité, télémétrie, analyse ou SDK de suivi tiers.

La surveillance de base du CPU, du disque, du réseau, des volumes et des processus ne demande pas d’autorisation administrateur. macOS peut demander l’approbation du composant d’arrière-plan signé et limité uniquement lorsque vous démarrez explicitement un suivi ; les emplacements protégés peuvent aussi exiger l’accès complet au disque. Vous contrôlez toujours le début et la fin.

Consultez la [Politique de confidentialité](PRIVACY.md) · [Politique de sécurité](SECURITY.md).

## Installation

1. Téléchargez le dernier DMG signé et notarisé depuis le [site officiel](https://finddiskkiller.com/fr/download/).
2. Ouvrez-le et faites glisser FindDiskKiller dans Applications.
3. Lancez FindDiskKiller depuis Applications.

Les versions officielles prennent en charge les Mac Apple silicon et Intel et incluent une somme SHA-256. Ne contournez pas Gatekeeper si la signature ou la notarisation échoue.

## Développement et documentation

<details>
<summary><strong>Compiler depuis les sources et exécuter les tests</strong></summary>

Le développement nécessite Xcode 16+ et XcodeGen 2.42.0+.

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

La version non signée couvre la surveillance de base, mais pas le suivi privilégié qui exige les identités officielles de l’app et du helper.

</details>

- [Plan produit et technique](docs/find-disk-killer-product-and-technical-plan.md)
- [Plan du suivi approfondi et de la santé SSD](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.md)
- [Liste de publication Web](docs/website-release-checklist.md)
- [Contribuer](CONTRIBUTING.md)
- [Mentions tierces](THIRD_PARTY_NOTICES.md)

## Assistance et licence

Utilisez [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues) pour les questions, bugs et suggestions. Signalez les vulnérabilités en privé via [GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new) et retirez chemins sensibles, noms d’utilisateur et numéros de série des diagnostics ou captures.

FindDiskKiller est open source sous [licence MIT](LICENSE).
