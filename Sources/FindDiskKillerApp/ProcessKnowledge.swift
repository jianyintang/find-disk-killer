import FindDiskKillerCore
import SwiftUI

struct ProcessKnowledgeProfile {
    let role: String
    let detail: String
    let symbol: String
    let color: Color
}

enum ProcessKnowledge {
    static func profile(for process: ProcessActivity) -> ProcessKnowledgeProfile {
        let name = process.name.lowercased()
        let path = process.executablePath.lowercased()

        if name == "kernel_task" {
            return profile("macOS 内核", "管理硬件、内存、驱动与系统级 CPU 调度。", "cpu", .blue)
        }
        if name == "launchd" {
            return profile("系统服务管理器", "负责启动、停止并监督 macOS 的系统服务和用户服务。", "gearshape.2", .blue)
        }
        if name.contains("windowserver") {
            return profile("窗口与图形服务", "合成屏幕上的窗口、动画与显示内容；高负载通常与窗口、显示器或图形更新有关。", "rectangle.3.group", .purple)
        }
        if matches(name, ["finder", "dock", "systemuiserver", "controlcenter", "notificationcenter"]) {
            return profile("macOS 桌面界面", "提供桌面、Dock、菜单栏、控制中心或通知等系统界面。", "macwindow", .purple)
        }
        if containsAny(name, ["mds", "mdworker", "corespotlight"]) {
            return profile("Spotlight 索引", "扫描文件内容并更新搜索索引；新文件、代码仓库或外接磁盘可能触发持续读写。", "magnifyingglass", .indigo)
        }
        if matches(name, ["cloudd", "bird", "fileproviderd"]) {
            return profile("云端与文件同步", "在本机与 iCloud 或文件提供商之间同步内容，可能产生下载、上传和磁盘写入。", "icloud", .cyan)
        }
        if containsAny(name, ["backupd", "timemachine"]) {
            return profile("Time Machine 备份", "扫描变化并写入备份目标；备份期间持续读取和写入通常属于预期行为。", "clock.arrow.circlepath", .green)
        }
        if containsAny(name, ["photoanalysis", "photolibrary", "mediaanalysis"]) {
            return profile("照片与媒体分析", "分析照片或媒体内容并维护资料库索引，可能阶段性占用 CPU 和磁盘。", "photo.on.rectangle.angled", .pink)
        }
        if containsAny(name, ["storagemanagement", "applicationsstorageextension", "storagekit"]) {
            return profile("存储空间分析", "扫描应用与文件以计算存储占用；分析期间可能出现较高 CPU 与磁盘读取。", "internaldrive", .teal)
        }
        if matches(name, ["tccd", "trustd", "syspolicyd", "securityd"]) {
            return profile("系统安全服务", "处理隐私授权、证书信任、代码签名或安全策略验证。", "lock.shield", .blue)
        }
        if containsAny(name, ["coreaudiod", "audiomxd"]) {
            return profile("系统音频服务", "管理音频设备、混音和应用音频流。", "speaker.wave.2", .orange)
        }
        if matches(name, ["mdnsresponder", "configd", "networkd", "rapportd", "sharingd", "apsd", "airportd"]) {
            return profile("系统网络服务", "负责网络配置、设备发现、推送或共享连接。", "network", .green)
        }
        if matches(name, ["fseventsd", "logd", "cfprefsd", "distnoted", "runningboardd", "powerd", "dasd"]) {
            return profile("macOS 后台服务", "维护文件事件、日志、偏好设置、进程生命周期或电源调度。", "gearshape", .secondary)
        }
        let isCodexAgent = process.brand == .codex || name.contains("codex")
        let isClaudeCode = process.brand == .claude && process.appBundlePath == nil
        if isCodexAgent || isClaudeCode {
            return profile("AI 开发工具", "运行对话、代码分析、索引或 agent 任务；处理大型工作区时可能持续使用 CPU、网络和磁盘。", "sparkles", .purple)
        }
        let isDesktopAIAssistant = path.contains("/chatgpt.app/")
            || path.contains("/claude.app/")
            || name.contains("chatgpt")
        if isDesktopAIAssistant {
            return profile("AI 助手", "提供对话、内容生成或代码协助；执行复杂任务时可能持续使用 CPU、网络和磁盘。", "sparkles", .purple)
        }
        if process.brand == .claude || name.contains("claude") {
            return profile("AI 开发工具", "运行对话、代码分析、索引或 agent 任务；处理大型工作区时可能持续使用 CPU、网络和磁盘。", "sparkles", .purple)
        }
        if matches(name, ["go", "git", "node", "clang", "rustc", "cargo"])
            || containsAny(name, ["xcode", "sourcekit", "swift-frontend", "golang", "python"]) {
            return profile("开发与构建工具", "执行编译、代码分析、依赖处理或脚本任务；构建期间的高 CPU 与写入通常是阶段性的。", "hammer", .orange)
        }
        if containsAny(name, ["chrome helper", "chromium helper", "webkit", "electron helper"]) {
            return profile("应用辅助进程", "为网页或桌面应用提供渲染、网络、GPU 或后台任务；同一应用通常会启动多个辅助进程。", "square.stack.3d.up", .blue)
        }
        if path.contains(".app/contents/") || process.appBundlePath != nil {
            return profile("用户应用", "这是已安装应用或其辅助进程；当前资源值汇总到所属应用。", "app", .accentColor)
        }
        if path.hasPrefix("/system/") || path.hasPrefix("/usr/libexec/")
            || path.hasPrefix("/sbin/") || path.hasPrefix("/usr/sbin/") {
            return profile("macOS 系统进程", "这是由 macOS 提供的后台进程；具体用途可结合可执行路径继续判断。", "gearshape.2", .secondary)
        }
        return profile("命令行进程", "无法仅凭名称可靠确定用途；可执行路径是判断来源和功能的主要依据。", "terminal", .secondary)
    }

    private static func profile(
        _ role: String,
        _ detail: String,
        _ symbol: String,
        _ color: Color
    ) -> ProcessKnowledgeProfile {
        ProcessKnowledgeProfile(
            role: L10n.text(role),
            detail: L10n.text(detail),
            symbol: symbol,
            color: color
        )
    }

    private static func matches(_ name: String, _ candidates: [String]) -> Bool {
        candidates.contains(name)
    }

    private static func containsAny(_ name: String, _ candidates: [String]) -> Bool {
        candidates.contains { name.contains($0) }
    }
}

struct ProcessLoadAssessment {
    let title: String
    let detail: String
    let symbol: String
    let color: Color

    static func assess(_ process: ProcessActivity) -> ProcessLoadAssessment {
        let network = process.isNetworkAvailable
            ? process.currentNetworkReceiveBytesPerSecond
                + process.currentNetworkSendBytesPerSecond
            : 0
        let activeDimensions = [
            process.currentCPUPercent >= 35,
            process.currentReadBytesPerSecond + process.currentWriteBytesPerSecond >= 10_000_000,
            network >= 10_000_000
        ].filter { $0 }.count

        if activeDimensions >= 2 {
            return assessment("多项资源同时活跃", "该进程正在同时使用计算、磁盘或网络资源；请结合下方实时值判断任务类型。", "waveform.path.ecg", .orange)
        }
        if process.currentCPUPercent >= 100 {
            return assessment("CPU 负载很高", "最近 5 秒至少占满一个逻辑核心；并行任务超过 100% 属于 macOS 的正常计量方式。", "cpu", .orange)
        }
        if process.currentCPUPercent >= 35 {
            return assessment("CPU 负载较高", "当前存在明显的计算任务，但是否异常取决于它是否持续以及是否符合你的操作。", "cpu", .yellow)
        }
        if process.currentWriteBytesPerSecond >= 50_000_000 {
            return assessment("磁盘写入很高", "正在持续产生大量数据；构建、下载、同步和缓存任务都可能出现这种负载。", "pencil.line", .orange)
        }
        if process.currentWriteBytesPerSecond >= 5_000_000 {
            return assessment("磁盘写入活跃", "当前有明确写入活动；持续时间比单次峰值更能说明是否异常。", "pencil.line", .yellow)
        }
        if process.currentReadBytesPerSecond >= 10_000_000 {
            return assessment("磁盘读取活跃", "当前正在扫描或载入较多数据，常见于索引、分析、构建和应用启动。", "eye", .teal)
        }
        if network >= 5_000_000 {
            return assessment("网络传输活跃", "当前有明显下载或上传；磁盘写入可能来自下载、同步或缓存。", "network", .green)
        }
        if process.currentCPUPercent >= 5
            || process.currentReadBytesPerSecond + process.currentWriteBytesPerSecond >= 500_000
            || network >= 500_000 {
            return assessment("当前有轻度活动", "资源使用处于较低水平，暂未表现出持续高负载。", "waveform", .blue)
        }
        if !process.isNetworkAvailable {
            return assessment("CPU 与磁盘接近空闲", "最近 5 秒没有明显的 CPU 或磁盘压力；网络数据当前不可用，无法判断网络是否空闲。", "pause.circle", .secondary)
        }
        return assessment("当前接近空闲", "最近 5 秒没有明显资源压力；列表中的区间总量可能来自更早的活动。", "pause.circle", .secondary)
    }

    private static func assessment(
        _ title: String,
        _ detail: String,
        _ symbol: String,
        _ color: Color
    ) -> ProcessLoadAssessment {
        ProcessLoadAssessment(
            title: L10n.text(title),
            detail: L10n.text(detail),
            symbol: symbol,
            color: color
        )
    }
}
