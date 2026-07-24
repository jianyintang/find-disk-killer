<div align="center">
  <img src="docs/assets/find-disk-killer-icon.png" width="136" height="136" alt="FindDiskKiller アプリアイコン">
  <h1>FindDiskKiller</h1>
  <p><strong>ディスクを使い続けているアプリを、ひと目で。</strong></p>
  <p>アプリのディスク I/O、CPU、ネットワーク、ファイル活動、ドライブの健全性を、macOS ネイティブのワークスペースに集約します。</p>
  <p>
    <a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> ·
    <a href="README.zh-TW.md">繁體中文</a> · <a href="README.ja.md">日本語</a> ·
    <a href="README.ko.md">한국어</a> · <a href="README.de.md">Deutsch</a> ·
    <a href="README.fr.md">Français</a> · <a href="README.es.md">Español</a> ·
    <a href="README.pt-BR.md">Português (Brasil)</a> · <a href="README.ru.md">Русский</a>
  </p>
  <p><strong>macOS 14 以降 · Apple シリコン / Intel · ローカル処理 · 10 言語対応</strong></p>
  <p><a href="https://finddiskkiller.com/ja/download/">ダウンロード</a> · <a href="https://finddiskkiller.com/ja/">公式サイト</a> · <a href="docs/find-disk-killer-product-and-technical-plan.md">製品モデル</a> · <a href="SUPPORT.md">サポート</a> · <a href="PRIVACY.md">プライバシー</a></p>
</div>

---

<p align="center">
  <img src="docs/assets/screenshots/overview-sustained-activity.webp" width="100%" alt="持続的なディスク活動、リソース推移、主なアプリを表示する FindDiskKiller の現在ワークスペース。">
</p>
<p align="center"><sub>持続的なディスク活動を見つけ、その原因となるアプリを特定します。</sub></p>

Mac が熱を持ち、ディスクが動き続けているのに、プロセス一覧だけでは理由が分からない。
FindDiskKiller は、そんな調査をアプリ中心に整理します。継続的な負荷を見つけ、対象アプリの
CPU、ディスク、ネットワーク、ファイル、ストレージの状況を、一つの流れで確認できます。

## ひとつの画面で分かること

| ワークスペース | 確認できる内容 |
| --- | --- |
| **アプリの活動** | 直近 5 秒の CPU、読み込み、書き込み、ダウンロード、アップロード。並べ替えと列幅変更に対応 |
| **タイムライン** | 1 分、15 分、1 時間の折れ線。ホバーで正確な時刻と値を表示 |
| **プロセス詳細** | 独立したウインドウで CPU、ディスク、ネットワーク、ファイルの情報を比較 |
| **ファイル活動** | 現在開いている場所と、直近 5 分間に変更が観測されたディレクトリ |
| **ファイルアクセス追跡** | オンデマンドの要求読み書き量、直近 5 秒の速度、セッション最大値、活発なファイルと検証済みプロセス |
| **ディスク** | マウント済みボリューム名と物理デバイスのスループット。外付けストレージにも対応 |
| **ドライブの健全性** | macOS が提供する場合に、温度、ホスト書き込み量、消耗度、予備領域、電源履歴、エラーを表示 |
| **メニューバー** | 通知を繰り返さず、現在の状態を静かに確認 |

## アプリからディスクまでを一つの流れで

### まず対象アプリを確認

<p align="center">
  <img src="docs/assets/screenshots/app-codex-overview.webp" width="100%" alt="CPU、ディスク I/O、ネットワークの時間推移を分けて表示する Codex アプリ詳細。">
</p>

### 次にファイルの場所と範囲を限定したアクセス情報を確認

<p align="center">
  <img src="docs/assets/screenshots/app-codex-file-activity.webp" width="100%" alt="関連する場所、書き込み可能なフォルダ、最近の変更を表示する Codex のファイル活動ビュー。">
</p>

<p align="center">
  <img src="docs/assets/screenshots/folder-access-trace.webp" width="100%" alt="要求された読み書き速度、活発なファイル、アクセス元プロセスを表示する時間制限付きフォルダ追跡。">
</p>

### 最後にストレージと健全性を確認

<p align="center">
  <img src="docs/assets/screenshots/disk-live-activity.webp" width="100%" alt="物理デバイスのスループット、マウント済みボリューム、ハードウェア診断を表示するディスクワークスペース。">
</p>

<p align="center">
  <img src="docs/assets/screenshots/disk-health.webp" width="100%" alt="SMART 状態、消耗、温度、ホスト書き込み、電源履歴、メディアエラーを表示するドライブ健全性ビュー。">
</p>

## 調査を途切れさせない設計

```text
継続的な負荷を検出
        |
        v
主なアプリを特定  -->  CPU / ディスク / ダウンロード / アップロード
        |
        v
開いているファイルと最近の変更を確認
        |
        v
必要なときだけ、時間制限付きのファイル／フォルダ追跡を開始
        |
        v
物理デバイスのスループットと健全性情報を確認
```

CPU は常に先頭に表示し、読み込みと書き込み、ダウンロードとアップロードを分離します。
現在値は直近 5 秒から計算。行を確認している間は表示順の更新だけを止め、クリック操作は妨げません。
プロセス詳細は独立したウインドウで開きます。

## 見せかけの精度を作らない

- **アプリのディスク I/O** はプロセスのカウンタで、すべてのストレージを含む合計です。
- **デバイスのスループット** は物理デバイスのカウンタで、`Macintosh HD` や `ExternalSSD` など分かりやすい名前で表示します。
- **最近の変更** は、その場所の変更を macOS が観測した事実であり、変更したプロセスを単独では特定しません。
- **ファイルアクセス追跡** は、成功したシステムコールで要求されたバイト数です。キャッシュ、APFS の遅延書き込み、圧縮、コピーオンライト、メモリマップ、観測漏れにより、物理ディスクや NAND の書き込み量とは異なります。
- **ドライブの健全性** は macOS が実際に返した項目だけを表示し、取得できない値をゼロに置き換えません。

任意のプロセスが特定の物理ディスクへ書き込んだ全バイトを正確に特定できる、とは主張しません。

## プライバシーと権限

監視と解析は Mac 上で完結します。現行版には広告、テレメトリ、行動解析、第三者の追跡 SDK はなく、
プロセス活動、ファイルパス、監視履歴、ディスクのシリアル番号をアップロードしません。

基本監視に管理者の承認は不要です。ファイルまたはフォルダの追跡を明示的に開始した場合だけ、
macOS が署名済みバックグラウンドコンポーネントの承認を求めることがあります。このコンポーネントは、
固定された引数と時間制限を持つ `/usr/bin/fs_usage` セッションだけを監督し、シェルや任意のコマンドは実行できません。

詳しくは [プライバシーポリシー](PRIVACY.md) と [セキュリティポリシー](SECURITY.md) をご覧ください。

## 動作環境とインストール

- macOS 14 以降
- Apple シリコンまたは Intel Mac
- 管理者アカウントが必要なのは、オンデマンドのファイルアクセス追跡を有効にするときだけです

正式版は公開後、Developer ID 署名と Apple の公証を受けた universal2 DMG として提供されます。

1. [公式サイト](https://finddiskkiller.com/ja/download/)から最新版をダウンロードします。
2. DMG を開き、FindDiskKiller を「アプリケーション」へドラッグします。
3. 「アプリケーション」から FindDiskKiller を起動します。

各正式版には SHA-256 を公開します。Gatekeeper の検証に失敗するパッケージでは、システムの保護機能を回避しないでください。

## ビルドとテスト

開発には Xcode 16 以降と XcodeGen 2.42.0 以降が必要です。

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

未署名の開発ビルドでは基本監視を検証できますが、権限が必要なファイルまたはフォルダの
追跡は実行できません。アプリと helper はメンテナーの Team ID で相互認証するため、
この機能は正式に署名されたビルドで検証する必要があります。バックグラウンドコンポーネントの
承認と、保護された場所に対するフルディスクアクセスは、macOS 上の別々の権限です。

クリーンなコミットから署名・公証済みの配布物を作成します。

```bash
make lint test
make release VERSION=1.0.0 BUILD_NUMBER=100
```

`SKIP_NOTARIZATION=1` の成果物はローカル検証専用で、公開できません。

## ドキュメントとサポート

- [製品・技術計画](docs/find-disk-killer-product-and-technical-plan.md)
- [詳細ファイル追跡と SSD 健全性計画](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.md)
- [Web 配布チェックリスト](docs/website-release-checklist.md)
- [コントリビューション](CONTRIBUTING.md)
- [サポート](SUPPORT.md) · [プライバシー](PRIVACY.md) · [セキュリティ](SECURITY.md) · [第三者に関する表示](THIRD_PARTY_NOTICES.md)

一般的な問い合わせは [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues) へ、
脆弱性は [GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new) から非公開で報告してください。

FindDiskKiller は [MIT License](LICENSE) のもとでオープンソースとして公開されています。
第三者のアプリマークは観測したソフトウェアの識別にのみ使用し、提携や推奨を示すものではありません。
