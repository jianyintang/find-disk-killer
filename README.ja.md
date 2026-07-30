<div align="center">
  <img src="docs/assets/find-disk-killer-icon.png" width="128" height="128" alt="FindDiskKiller アプリアイコン">
  <h1>FindDiskKiller</h1>
  <p><strong>ディスクを使い続けているものを見つける。</strong></p>
  <p>アプリのディスク I/O から始め、ファイル活動、AI Agent ストレージ、物理ディスクの証拠を一つの流れで追跡します。</p>
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
  <p><strong>macOS 14+ · Apple silicon / Intel · 100% ローカル処理</strong></p>
  <p>
    <a href="https://finddiskkiller.com/ja/download/"><strong>macOS 版をダウンロード</strong></a> ·
    <a href="https://finddiskkiller.com/ja/">公式サイト</a> ·
    <a href="https://finddiskkiller.com/ja/how-it-works/">仕組み</a> ·
    <a href="PRIVACY.md">プライバシー</a> ·
    <a href="SUPPORT.md">サポート</a>
  </p>
</div>

---

<a href="docs/assets/screenshots/overview-sustained-activity.webp">
  <img src="docs/assets/screenshots/overview-sustained-activity.webp" width="100%" alt="持続的なディスク活動、リソース推移、主なアプリを完全に表示する FindDiskKiller の現在ワークスペース。">
</a>

<p align="center"><sub>持続的なディスク活動を見つけ、その原因となるアプリを特定します。クリックすると元画像を表示します。</sub></p>

FindDiskKiller は一つの目的に特化したネイティブ macOS ツールです。持続的なディスク活動の兆候から、その原因となるアプリ、ファイル、物理デバイスまでを追跡します。CPU、ディスク、ネットワークの証拠をアプリ中心にまとめ、複数のシステムツールを行き来する必要をなくします。

<p align="center">
  <strong>100%</strong> ローカル処理　·　<strong>0</strong> データ送信　·　<strong>10</strong> 言語　·　<strong>macOS 14+</strong>
</p>

## すべての情報を一つのワークスペースに

### AI Agent ストレージ

Codex と Claude は、会話、サブエージェントセッション、スナップショット、可視化、共有データベースを蓄積します。AI Storage は明示的な操作後にだけローカル分析を開始し、thread または session ごとに容量を割り当て、完全削除前に確認できます。

<a href="docs/assets/screenshots/ai-storage-overview.webp">
  <img src="docs/assets/screenshots/ai-storage-overview.webp" width="100%" alt="Codex と Claude のチャット、グローバル、未割り当て領域を分けて示す AI Storage の概要。">
</a>

<p align="center"><sub>提供元全体の容量を測定し、チャット、グローバルデータ、未割り当て領域を分離します。</sub></p>

<p align="center">
  <a href="docs/assets/screenshots/ai-storage-thread-details.webp"><img src="docs/assets/screenshots/ai-storage-thread-details.webp" width="57%" alt="活動時刻、サブエージェント数、選択した thread の完全な構成を示す Codex AI Storage。"></a>
  <a href="docs/assets/screenshots/ai-storage-batch-cleanup.webp"><img src="docs/assets/screenshots/ai-storage-batch-cleanup.webp" width="41%" alt="完全削除前に選択範囲と即時解放見込みを示す AI Agent 一括クリーンアップ。"></a>
</p>

<p align="center"><sub>左：容量を個別の会話に割り当て　·　右：期間、プロジェクト、会話を完全削除前に確認</sub></p>

分析は自動で始まりません。活動中または識別情報が変わったセッションはスキップし、未対応の提供元でデータベースの直接書き込みや transcript の手動削除へ切り替えることもありません。Claude Desktop と Cowork のセッションは現在も Claude Desktop 内で削除します。

### アプリ活動とファイルの証拠

アプリの CPU、ディスク I/O、ネットワーク推移を比較し、開いている場所と最近変更されたディレクトリへ進みます。より明確な証拠が必要な場合だけ、時間制限付きのファイルまたはフォルダ追跡を開始します。

<p align="center">
  <a href="docs/assets/screenshots/app-codex-overview.webp"><img src="docs/assets/screenshots/app-codex-overview.webp" width="49%" alt="CPU、ディスク I/O、ネットワークのタイムラインを分けて表示する Codex アプリ詳細。"></a>
  <a href="docs/assets/screenshots/app-codex-file-activity.webp"><img src="docs/assets/screenshots/app-codex-file-activity.webp" width="49%" alt="関連する場所、書き込み可能なフォルダ、最近の変更を表示する Codex のファイル活動。"></a>
</p>

<p align="center"><sub>左：活動が持続しているか判断　·　右：アプリが関係する場所へ移動</sub></p>

<p align="center">
  <a href="docs/assets/screenshots/folder-access-trace.webp"><img src="docs/assets/screenshots/folder-access-trace.webp" width="86%" alt="要求された読み書き速度、活発なファイル、アクセス元プロセスを示す時間制限付きフォルダ追跡。"></a>
</p>

<p align="center"><sub>追跡は明示的に開始した後だけ動作し、要求 I/O、活発なファイル、検証済みプロセスセッションを表示します。</sub></p>

### 物理ディスクと健全性

Macintosh HD や外付けドライブなどの分かりやすいボリューム名を物理デバイスのスループットに対応付け、macOS とハードウェアが実際に公開する SMART/NVMe 項目を確認します。

<p align="center">
  <a href="docs/assets/screenshots/disk-live-activity.webp"><img src="docs/assets/screenshots/disk-live-activity.webp" width="49%" alt="物理デバイスのスループット、マウント済みボリューム、ハードウェア診断を表示するディスク画面。"></a>
  <a href="docs/assets/screenshots/disk-health.webp"><img src="docs/assets/screenshots/disk-health.webp" width="49%" alt="SMART 状態、消耗、温度、ホスト書き込み、電源履歴、メディアエラーを表示するディスク健全性画面。"></a>
</p>

<p align="center"><sub>左：どの物理デバイスが動作中か確認　·　右：デバイスが報告する健全性情報を確認</sub></p>

## 見せかけの精度を作らない

FindDiskKiller は関連する証拠をまとめて示しますが、意味の異なる測定を一つの数値に強制しません：

- **アプリ I/O** は全ストレージへのプロセス要求であり、物理 NAND の読み書きではありません。
- **物理デバイスのスループット** を単一プロセスへ正確に割り当てることはできず、アプリ値とデバイス値が一致する必要もありません。
- **最近変更された場所** は macOS が変更を観測したことを示しますが、それだけで書き込み元は特定できません。
- **AI データベースの割り当て** は明示された論理推定値であり、即時に解放できる物理容量ではありません。

欠落、部分的、未対応の証拠はゼロではなく利用不可として表示します。

## プライバシーと権限

監視、分析、表示はすべて Mac 内で完結します。現在のリリースはプロセス名、ファイルパス、ディスクシリアル番号、監視履歴を送信せず、広告、テレメトリ、分析、第三者追跡 SDK も含みません。

基本的な CPU、ディスク、ネットワーク、ボリューム、プロセス監視に管理者承認は不要です。ファイルまたはディレクトリ追跡を明示的に開始したときだけ、macOS が署名済みの固定目的バックグラウンドコンポーネントの承認を求める場合があります。保護された場所にはフルディスクアクセスが必要なこともあります。追跡の開始と停止は常にユーザーが制御します。

詳細は [プライバシーポリシー](PRIVACY.md) · [セキュリティポリシー](SECURITY.md).

## インストール

1. [公式サイト](https://finddiskkiller.com/ja/download/)から最新の署名・公証済み DMG をダウンロードします。
2. DMG を開き、FindDiskKiller をアプリケーションフォルダへドラッグします。
3. アプリケーションから FindDiskKiller を起動します。

正式版は Apple silicon と Intel Mac に対応し、SHA-256 チェックサムを提供します。署名または公証の検証に失敗した場合は Gatekeeper を回避しないでください。

## 開発とドキュメント

<details>
<summary><strong>ソースからビルドしてテストを実行</strong></summary>

開発には Xcode 16+ と XcodeGen 2.42.0+ が必要です。

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

未署名ビルドでは基本監視を検証できますが、正式に署名された App と helper の識別情報が必要な特権ファイル追跡は実行できません。

</details>

- [製品・技術計画](docs/find-disk-killer-product-and-technical-plan.md)
- [詳細ファイル追跡と SSD 健全性計画](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.md)
- [Web 配布チェックリスト](docs/website-release-checklist.md)
- [コントリビューション](CONTRIBUTING.md)
- [第三者通知](THIRD_PARTY_NOTICES.md)

## サポートとライセンス

質問、バグ、機能要望には [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues) を利用してください。脆弱性は [GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new) から非公開で報告し、診断やスクリーンショットから機密パス、ユーザー名、ディスクシリアル番号を除いてください。

FindDiskKiller は [MIT License](LICENSE) の下でオープンソースです。
