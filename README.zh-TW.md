<div align="center">
  <img src="docs/assets/find-disk-killer-icon.png" width="128" height="128" alt="FindDiskKiller App 圖示">
  <h1>FindDiskKiller</h1>
  <p><strong>看見是誰在持續使用你的磁碟。</strong></p>
  <p>從 App 磁碟 I/O 出發，沿著檔案活動、AI Agent 空間與實體磁碟證據完成一次連貫調查。</p>
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
  <p><strong>macOS 14+ · Apple silicon 與 Intel · 100% 本機處理</strong></p>
  <p>
    <a href="https://finddiskkiller.com/zh-tw/download/"><strong>下載 macOS 版</strong></a> ·
    <a href="https://finddiskkiller.com/zh-tw/">官網</a> ·
    <a href="https://finddiskkiller.com/zh-tw/how-it-works/">運作方式</a> ·
    <a href="PRIVACY.md">隱私權</a> ·
    <a href="SUPPORT.md">支援</a>
  </p>
</div>

---

<a href="docs/assets/screenshots/overview-sustained-activity.webp">
  <img src="docs/assets/screenshots/overview-sustained-activity.webp" width="100%" alt="FindDiskKiller 目前工作區，完整顯示持續磁碟活動、資源趨勢與主要 App。">
</a>

<p align="center"><sub>找出持續磁碟活動，並定位背後的 App。按一下圖片可查看原圖。</sub></p>

FindDiskKiller 是一款原生 macOS 工具，專注於一件事：從持續磁碟活動的訊號出發，逐步找到背後的 App、檔案與實體裝置。CPU、磁碟與網路證據都以 App 為中心，無需在多個系統工具之間拼湊脈絡。

<p align="center">
  <strong>100%</strong> 本機處理　·　<strong>0</strong> 資料上傳　·　<strong>10</strong> 種介面語言　·　<strong>macOS 14+</strong>
</p>

## 所有資訊，一個工作區

### AI Agent 空間

Codex 與 Claude 會累積逐字稿、子代理工作階段、快照、視覺化與共用資料庫。AI Storage 只在明確按下按鈕後開始本機分析，將空間歸屬到個別 thread 或 session，並在永久刪除前提供完整複核。

<a href="docs/assets/screenshots/ai-storage-overview.webp">
  <img src="docs/assets/screenshots/ai-storage-overview.webp" width="100%" alt="AI Storage 總覽，分別顯示 Codex 與 Claude 的聊天、全域與未歸屬空間。">
</a>

<p align="center"><sub>先測量提供者的完整占用，再區分聊天、全域資料與未歸屬空間。</sub></p>

<p align="center">
  <a href="docs/assets/screenshots/ai-storage-thread-details.webp"><img src="docs/assets/screenshots/ai-storage-thread-details.webp" width="57%" alt="Codex AI Storage 清單，顯示活動時間、子代理數量及所選 thread 的完整空間構成。"></a>
  <a href="docs/assets/screenshots/ai-storage-batch-cleanup.webp"><img src="docs/assets/screenshots/ai-storage-batch-cleanup.webp" width="41%" alt="AI Agent 批次清理複核畫面，在永久刪除前顯示選取範圍與預計立即釋放空間。"></a>
</p>

<p align="center"><sub>左：把空間歸屬到具體對話　·　右：永久刪除前按時間、專案與對話複核</sub></p>

分析不會自動開始。活動中或身分已變更的工作階段會被跳過；不支援的提供者不會降級為直接寫入資料庫或手動刪除 transcript。Claude Desktop 與 Cowork 工作階段目前仍須在 Claude Desktop 內刪除。

### App 活動與檔案證據

先比較 App 的 CPU、磁碟 I/O 與網路趨勢，再進入目前開啟的位置和最近變更的目錄。需要更明確的證據時，可主動開始一次有時間範圍的檔案或資料夾追蹤。

<p align="center">
  <a href="docs/assets/screenshots/app-codex-overview.webp"><img src="docs/assets/screenshots/app-codex-overview.webp" width="49%" alt="Codex App 詳細資料，分別顯示 CPU、磁碟 I/O 與網路時間軸。"></a>
  <a href="docs/assets/screenshots/app-codex-file-activity.webp"><img src="docs/assets/screenshots/app-codex-file-activity.webp" width="49%" alt="Codex 檔案活動畫面，顯示相關位置、可寫入資料夾與最近變更。"></a>
</p>

<p align="center"><sub>左：判斷資源活動是否持續　·　右：進入 App 實際涉及的位置</sub></p>

<p align="center">
  <a href="docs/assets/screenshots/folder-access-trace.webp"><img src="docs/assets/screenshots/folder-access-trace.webp" width="86%" alt="有時間範圍的資料夾追蹤，顯示請求讀寫速率、活躍檔案與存取程序。"></a>
</p>

<p align="center"><sub>追蹤只在明確啟動後執行，顯示請求 I/O、活躍檔案與已驗證的程序工作階段。</sub></p>

### 實體磁碟與健康狀態

把 Macintosh HD、外接硬碟等熟悉的卷宗名稱對應到實體裝置吞吐量，再查看 macOS 與硬體實際提供的 SMART/NVMe 健康欄位。

<p align="center">
  <a href="docs/assets/screenshots/disk-live-activity.webp"><img src="docs/assets/screenshots/disk-live-activity.webp" width="49%" alt="磁碟工作區，顯示實體裝置吞吐量、掛載卷宗與硬體診斷。"></a>
  <a href="docs/assets/screenshots/disk-health.webp"><img src="docs/assets/screenshots/disk-health.webp" width="49%" alt="磁碟健康狀態，顯示 SMART 狀態、耗損、溫度、主機寫入、通電記錄與媒體錯誤。"></a>
</p>

<p align="center"><sub>左：哪個實體裝置正在忙碌　·　右：裝置實際報告了哪些健康資訊</sub></p>

## 不製造虛假的精確度

FindDiskKiller 會把相關證據放在一起，但不會把不同口徑的資料強行解釋成同一種測量：

- **App I/O** 是程序向所有儲存裝置提出的請求量，不等於實體 NAND 讀寫量。
- **實體裝置吞吐量** 無法精確歸屬到單一程序，App 資料與裝置資料不要求相加相等。
- **最近變更的位置** 只代表 macOS 觀察到變更，不能單獨證明寫入者。
- **AI 資料庫歸屬** 是清楚標示的邏輯估算，不是立即可釋放的實體空間。

缺失、覆蓋不足或硬體不支援的證據會顯示為無法取得，而不是用零填補。

## 隱私權與權限

所有監控、分析與顯示都在 Mac 本機完成。目前版本不會上傳程序名稱、檔案路徑、磁碟序號或監控歷程，也不包含廣告、遙測、分析或第三方追蹤 SDK。

基本 CPU、磁碟、網路、卷宗與程序監控不需管理員批准。只有明確開始檔案或目錄追蹤時，macOS 才可能要求批准已簽署、用途固定的背景元件；受保護的位置可能還需要「完整磁碟存取權」。追蹤何時開始與停止始終由你控制。

完整內容請閱讀 [隱私權政策](PRIVACY.md) · [安全性政策](SECURITY.md).

## 安裝

1. 從[官網](https://finddiskkiller.com/zh-tw/download/)下載最新已簽署、已公證的 DMG。
2. 開啟 DMG，將 FindDiskKiller 拖入「應用程式」資料夾。
3. 從「應用程式」啟動 FindDiskKiller。

正式版本支援 Apple silicon 與 Intel Mac，並提供 SHA-256 校驗值。簽章或公證驗證失敗時，請勿繞過 Gatekeeper。

## 開發與文件

<details>
<summary><strong>從原始碼建置並執行測試</strong></summary>

開發需要 Xcode 16+ 與 XcodeGen 2.42.0+。

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

未簽署版本可驗證基本監控，但無法完成需要正式簽署 App 與 helper 身分的特權檔案追蹤。

</details>

- [產品與技術計畫](docs/find-disk-killer-product-and-technical-plan.md)
- [深度檔案追蹤與 SSD 健康計畫](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.md)
- [官網發佈檢查表](docs/website-release-checklist.md)
- [參與貢獻](CONTRIBUTING.md)
- [第三方聲明](THIRD_PARTY_NOTICES.md)

## 支援與授權

一般問題、缺陷與功能建議請使用 [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues)。安全漏洞請透過 [GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new) 私下回報；提交診斷或截圖前，請移除敏感路徑、使用者名稱與磁碟序號。

FindDiskKiller 以 [MIT License](LICENSE) 開放原始碼。
