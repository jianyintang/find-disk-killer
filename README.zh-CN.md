<div align="center">
  <img src="docs/assets/find-disk-killer-icon.png" width="128" height="128" alt="FindDiskKiller 应用图标">
  <h1>FindDiskKiller</h1>
  <p><strong>看见是谁在持续使用你的磁盘。</strong></p>
  <p>从应用磁盘 I/O 出发，沿着文件活动、AI Agent 空间与物理磁盘证据完成一次连贯排查。</p>
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
  <p><strong>macOS 14+ · Apple silicon 与 Intel · 100% 本机处理</strong></p>
  <p>
    <a href="https://finddiskkiller.com/zh-cn/download/"><strong>下载 macOS 版</strong></a> ·
    <a href="https://finddiskkiller.com/zh-cn/">官网</a> ·
    <a href="https://finddiskkiller.com/zh-cn/how-it-works/">工作原理</a> ·
    <a href="PRIVACY.md">隐私</a> ·
    <a href="SUPPORT.md">支持</a>
  </p>
</div>

---

<a href="docs/assets/screenshots/overview-sustained-activity.webp">
  <img src="docs/assets/screenshots/overview-sustained-activity.webp" width="100%" alt="FindDiskKiller 当前状态工作区，完整展示持续磁盘活动、资源趋势和主要应用。">
</a>

<p align="center"><sub>发现持续磁盘活动，并定位背后的应用。点击图片可查看原图。</sub></p>

FindDiskKiller 是一个原生 macOS 工具，专注于一件事：从持续磁盘活动的信号出发，逐步找到背后的应用、文件与物理设备。CPU、磁盘读写和网络数据都以应用为中心呈现，无需在多个系统工具之间拼凑上下文。

<p align="center">
  <strong>100%</strong> 本机处理　·　<strong>0</strong> 数据上传　·　<strong>10</strong> 种界面语言　·　<strong>macOS 14+</strong>
</p>

## 所有信息，一个工作区

### AI Agent 空间

Codex 与 Claude 会积累聊天记录、子代理会话、快照、可视化和共享数据库。AI Storage 只在你明确点击后开始本机分析，将空间归因到具体 thread 或 session，并在永久删除前提供完整复核。

<a href="docs/assets/screenshots/ai-storage-overview.webp">
  <img src="docs/assets/screenshots/ai-storage-overview.webp" width="100%" alt="AI Storage 总览，分别展示 Codex 与 Claude 的聊天、全局和未归因空间。">
</a>

<p align="center"><sub>先测量提供方的完整占用，再区分聊天、全局数据与未归因空间。</sub></p>

<p align="center">
  <a href="docs/assets/screenshots/ai-storage-thread-details.webp"><img src="docs/assets/screenshots/ai-storage-thread-details.webp" width="57%" alt="Codex AI Storage 列表，按 thread 展示活动时间、子代理数量和所选 thread 的完整空间构成。"></a>
  <a href="docs/assets/screenshots/ai-storage-batch-cleanup.webp"><img src="docs/assets/screenshots/ai-storage-batch-cleanup.webp" width="41%" alt="AI Agent 批量清理复核界面，在永久删除前展示选择范围与预计立即释放空间。"></a>
</p>

<p align="center"><sub>左：追溯到具体对话　·　右：永久删除前按时间、项目与对话复核</sub></p>

分析不会自动开始。活动中或身份已变化的会话会被跳过；不支持的提供方不会降级为直接写数据库或手工删除 transcript。Claude Desktop 与 Cowork 会话目前仍需在 Claude Desktop 内删除。

### 应用活动与文件证据

先对照应用的 CPU、磁盘 I/O 与网络趋势，再进入它当前打开的位置和最近变化的目录。需要更明确的证据时，可以主动开始一次有时间边界的文件或文件夹追踪。

<p align="center">
  <a href="docs/assets/screenshots/app-codex-overview.webp"><img src="docs/assets/screenshots/app-codex-overview.webp" width="49%" alt="Codex 应用详情，分别展示 CPU、磁盘 I/O 和网络时间线。"></a>
  <a href="docs/assets/screenshots/app-codex-file-activity.webp"><img src="docs/assets/screenshots/app-codex-file-activity.webp" width="49%" alt="Codex 文件活动视图，展示相关位置、可写目录和最近变化。"></a>
</p>

<p align="center"><sub>左：判断资源活动是否持续　·　右：进入应用实际涉及的位置</sub></p>

<p align="center">
  <a href="docs/assets/screenshots/folder-access-trace.webp"><img src="docs/assets/screenshots/folder-access-trace.webp" width="86%" alt="有时间边界的文件夹追踪，展示请求读写速率、活跃文件和访问进程。"></a>
</p>

<p align="center"><sub>追踪只在明确启动后运行，展示请求读写量、活跃文件与已验证的进程会话。</sub></p>

### 物理磁盘与健康状态

把 Macintosh HD、外接硬盘等熟悉的卷名映射到物理设备吞吐，再查看 macOS 与硬件实际提供的 SMART/NVMe 健康字段。

<p align="center">
  <a href="docs/assets/screenshots/disk-live-activity.webp"><img src="docs/assets/screenshots/disk-live-activity.webp" width="49%" alt="磁盘工作区，展示物理设备吞吐、挂载卷和硬件诊断。"></a>
  <a href="docs/assets/screenshots/disk-health.webp"><img src="docs/assets/screenshots/disk-health.webp" width="49%" alt="磁盘健康视图，展示 SMART 状态、磨损、温度、主机写入、通电记录和介质错误。"></a>
</p>

<p align="center"><sub>左：哪个物理设备正在繁忙　·　右：设备实际报告了哪些健康信息</sub></p>

## 不制造虚假的精确度

FindDiskKiller 会把相关证据放在一起，但不会把不同口径的数据强行解释成同一种测量：

- **应用 I/O** 是进程向所有存储发出的请求量，不等于物理 NAND 读写量。
- **物理设备吞吐** 无法精确归因到某一个进程，应用数据与设备数据不要求相加相等。
- **最近变化的位置** 说明 macOS 观察到了变化，但不能单独证明写入者是谁。
- **AI 数据库归因** 是明确标注的逻辑估算，不会被描述成立即可释放的物理空间。

缺失、覆盖不足或硬件不支持的数据会明确显示为不可用，而不是用零填充。

## 隐私与权限

所有监控、分析与展示都在 Mac 本机完成。当前版本不上传进程名、文件路径、磁盘序列号或监控历史，也不包含广告、遥测、分析或第三方跟踪 SDK。

基础 CPU、磁盘、网络、卷和进程监控无需管理员权限。只有当你主动开始文件或目录访问追踪时，macOS 才可能要求批准已签名、用途固定的后台组件；受保护的位置可能还需要“完全磁盘访问权限”。追踪何时开始和停止始终由你控制。

完整说明请阅读[隐私政策](PRIVACY.md)与[安全政策](SECURITY.md)。

## 安装

1. 从[官网](https://finddiskkiller.com/zh-cn/download/)下载最新的已签名、已公证 DMG。
2. 打开 DMG，将 FindDiskKiller 拖入“应用程序”文件夹。
3. 从“应用程序”启动 FindDiskKiller。

正式版本支持 Apple silicon 与 Intel Mac，并提供 SHA-256 校验值。签名或公证验证失败时，请勿绕过 Gatekeeper。

## 开发与文档

<details>
<summary><strong>从源码构建并运行测试</strong></summary>

开发需要 Xcode 16+ 与 XcodeGen 2.42.0+。

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

未签名构建可以验证基础监控，但不能完成特权文件追踪；该流程要求 App 与 helper 具备正式签名身份。

</details>

- [产品与技术计划](docs/find-disk-killer-product-and-technical-plan.md)
- [深度文件追踪与 SSD 健康计划](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.md)
- [官网发布检查表](docs/website-release-checklist.md)
- [参与贡献](CONTRIBUTING.md)
- [第三方声明](THIRD_PARTY_NOTICES.md)

## 支持与许可

普通问题、缺陷与功能建议请使用 [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues)。安全漏洞请通过 [GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new) 私下报告；提交诊断或截图前，请移除敏感路径、用户名和磁盘序列号。

FindDiskKiller 以 [MIT License](LICENSE) 开源。
