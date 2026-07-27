<div align="center">
  <img src="docs/assets/find-disk-killer-icon.png" width="136" height="136" alt="FindDiskKiller 应用图标">
  <h1>FindDiskKiller</h1>
  <p><strong>看见是谁在持续使用你的磁盘。</strong></p>
  <p>将应用磁盘 I/O、CPU、网络、文件活动和磁盘健康证据集中在一个原生 macOS 工作区中。</p>
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
  <p><strong>macOS 14+ · Apple 芯片与 Intel · 本机处理 · 10 种界面语言</strong></p>
  <p>
    <a href="https://finddiskkiller.com/zh-cn/download/">下载</a> ·
    <a href="https://finddiskkiller.com/zh-cn/">官网</a> ·
    <a href="docs/find-disk-killer-product-and-technical-plan.md">产品模型</a> ·
    <a href="SUPPORT.md">支持</a> ·
    <a href="PRIVACY.md">隐私</a>
  </p>
</div>

---

<p align="center">
  <img src="docs/assets/screenshots/overview-sustained-activity.webp" width="100%" alt="FindDiskKiller 当前状态工作区，展示持续磁盘活动、资源趋势和主要应用。">
</p>
<p align="center"><sub>发现持续磁盘活动，并定位背后的应用。</sub></p>

当 Mac 开始发热、磁盘持续繁忙，而一张进程列表又无法解释原因时，
FindDiskKiller 会把排查过程重新组织成以应用为中心的工作流：先识别持续负载，
再查看相关应用的 CPU、磁盘、网络、文件和存储上下文，不必在多个工具之间拼凑线索。

## 一眼看清

| 工作区 | 能够看到什么 |
| --- | --- |
| **应用活动** | 最近 5 秒 CPU、读取、写入、下载和上传；支持排序、调整列宽和原生应用图标 |
| **时间曲线** | 1 分钟、15 分钟和 1 小时直线折线，悬停查看精确时间与数值 |
| **进程详情** | 使用独立窗口并排比较应用 CPU、磁盘、网络和文件证据 |
| **文件活动** | 当前打开的位置，以及最近 5 分钟内观察到变化的目录 |
| **文件访问追踪** | 按需查看请求读写总量、最近 5 秒速率、会话峰值、活跃文件和已验证进程 |
| **磁盘** | 以用户认识的挂载卷名展示物理设备吞吐，包括外接存储 |
| **磁盘健康** | 在 macOS 提供时展示温度、累计主机写入、磨损、备用空间、通电记录和错误 |
| **菜单栏** | 安静查看当前状态，不使用反复通知打扰用户 |
| **历史分析** | 可选保存本机聚合历史，查看 7 天、30 天和 1 年趋势、覆盖率、周期对比与主要应用 |

## 从应用到磁盘的完整视图

### 先确认负责的应用

<p align="center">
  <img src="docs/assets/screenshots/app-codex-overview.webp" width="100%" alt="Codex 应用详情，分别展示 CPU、磁盘 I/O 和网络时间曲线。">
</p>

### 再查看文件位置和有边界的访问证据

<p align="center">
  <img src="docs/assets/screenshots/app-codex-file-activity.webp" width="100%" alt="Codex 文件活动视图，展示相关位置、可写目录和最近变化。">
</p>

<p align="center">
  <img src="docs/assets/screenshots/folder-access-trace.webp" width="100%" alt="有时限的目录追踪，展示请求读写速率、活跃文件和访问进程。">
</p>

### 最后核对存储设备与健康信息

<p align="center">
  <img src="docs/assets/screenshots/disk-live-activity.webp" width="100%" alt="磁盘工作区，展示物理设备吞吐、挂载卷和硬件诊断。">
</p>

<p align="center">
  <img src="docs/assets/screenshots/disk-health.webp" width="100%" alt="磁盘健康视图，展示 SMART 状态、磨损、温度、主机写入、通电记录和介质错误。">
</p>

## 一条完整的排查路径

```text
发现持续负载
      |
      v
找到主要应用  -->  CPU / 磁盘 / 下载 / 上传
      |
      v
查看打开文件与最近变化
      |
      v
按需启动有时限的文件或目录追踪
      |
      v
核对物理设备吞吐与可用健康证据
```

交互面向高频排查进行了优化：CPU 始终位于第一项，读取与写入分开，下载与上传分开；
实时值取最近 5 秒；悬停时列表暂停视觉重排但仍可点击；进程详情使用独立窗口。

## 不制造虚假的精确度

FindDiskKiller 始终区分 macOS 提供的不同证据：

- **应用磁盘 I/O** 来自进程计数器，代表该进程涉及所有存储的总量。
- **设备吞吐** 来自物理设备计数器，并通过 `Macintosh HD`、`ExternalSSD` 等卷名呈现。
- **最近变化** 只能说明系统观察到某个位置发生变化，不能单独确认修改进程。
- **文件访问追踪** 统计成功系统调用向系统请求的字节。缓存、APFS 写回、压缩、
  写时复制、内存映射和覆盖缺口都会让它不同于物理磁盘或 NAND 写入。
- **磁盘健康** 只展示 macOS 实际提供的字段；缺失值显示为不可用，而不是零。

产品不会声称能够精确计算任意进程向某块物理磁盘写入的每一个字节。

## 隐私与权限

监控和分析全部在本机完成。当前版本不包含广告、遥测、行为分析或第三方追踪 SDK，
也不会上传进程活动、文件路径、监控历史或磁盘序列号。

长期历史默认关闭。开启后，逐秒采样先在内存聚合，每分钟最多用一个 SQLite 事务保存；
分钟明细只保留 24 小时，历史分析使用 15 分钟和小时聚合。用户可严格选择 7 天、30 天
或 1 个本地日历年，自动空间上限分别为 32 MB、64 MB 和 128 MB，绝对上限 160 MB。
历史库不保存 PID、完整路径、逐秒样本、文件追踪明细或磁盘序列号，并可随时在设置中清除。

“登录时启动”使用 macOS 原生登录项。默认登录后安静驻留菜单栏，用户可以单独选择是否
同时打开主窗口。

基础监控不申请管理员权限。只有当你明确开始文件或目录追踪时，macOS 才可能要求批准
FindDiskKiller 的签名后台组件。它只能监管参数固定且有时限的 `/usr/bin/fs_usage`
会话，不能执行 shell 或任意命令，并可在设置中停用和移除。

完整说明见 [隐私政策](PRIVACY.md) 与 [安全政策](SECURITY.md)。

## 系统要求与安装

- macOS 14 或更高版本
- Apple 芯片或 Intel Mac
- 仅在启用按需文件访问追踪时需要管理员账户

正式版本发布后，将以 Developer ID 签名、Apple 公证的 universal2 DMG 提供：

1. 从[官网](https://finddiskkiller.com/zh-cn/download/)下载最新版。
2. 打开 DMG，将 FindDiskKiller 拖入“应用程序”。
3. 从“应用程序”启动 FindDiskKiller。

每个正式版本都会发布 SHA-256。若软件包无法通过 Gatekeeper 验证，请勿绕过系统安全检查。

## 构建与测试

开发需要 Xcode 16 或更高版本，以及 XcodeGen 2.42.0 或更高版本。

```bash
git clone https://github.com/jianyintang/find-disk-killer.git
cd find-disk-killer
xcodegen generate
xcodebuild -project FindDiskKiller.xcodeproj \
  -scheme FindDiskKillerApp \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO build
swift test
```

无签名开发构建可验证基础监控，但不能完成需要特权的文件或目录追踪。App 与 helper
会通过维护者的 Team ID 相互验签，因此该流程必须使用官方签名构建验证。批准后台组件
与为受保护位置授予“完全磁盘访问权限”是两项独立的 macOS 权限，前者不会自动授予后者。

从干净提交创建签名并公证的官网发行包：

```bash
make lint test
make release VERSION=1.0.0 BUILD_NUMBER=100
```

设置 `SKIP_NOTARIZATION=1` 生成的内容只用于本地彩排，绝不能公开发布。

## 文档与支持

- [产品与技术方案](docs/find-disk-killer-product-and-technical-plan.md)
- [深度文件追踪与 SSD 健康方案](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.md)
- [官网发布检查表](docs/website-release-checklist.md)
- [参与贡献](CONTRIBUTING.md)
- [支持](SUPPORT.md) · [隐私](PRIVACY.md) · [安全](SECURITY.md) · [第三方声明](THIRD_PARTY_NOTICES.md)

普通问题请使用 [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues)。
安全漏洞请通过 [GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new)
私密报告，并在诊断信息中遮挡路径、用户名和序列号。

FindDiskKiller 按 [MIT License](LICENSE) 开源。第三方应用标识仅用于识别
被观察的软件，不代表合作、认可或背书。
