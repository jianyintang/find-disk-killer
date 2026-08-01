import FindDiskKillerCore
import Foundation

enum StorageSourceDestination: Equatable {
    case tailoredAnalysis
    case agentAnalysis(AgentStorageProvider)

    static func destination(for sourceID: StorageSourceID) -> Self {
        sourceID.agentStorageProvider.map(Self.agentAnalysis) ?? .tailoredAnalysis
    }
}

extension StorageSourceID {
    var agentStorageProvider: AgentStorageProvider? {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .openCode: .openCode
        default: nil
        }
    }
}

extension AgentStorageProvider {
    var storageSourceID: StorageSourceID {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .openCode: .openCode
        }
    }
}

enum StorageSourceResultAccess: Equatable {
    case available
    case storageResultRequired
    case agentResultRequired(AgentStorageProvider)

    var canPresent: Bool { self == .available }

    static func resolve(
        sourceID: StorageSourceID,
        storageSnapshot: StorageAnalysisSnapshot?,
        agentSnapshot: AgentStorageSnapshot?
    ) -> Self {
        guard storageSnapshot?.result(for: sourceID) != nil else {
            return .storageResultRequired
        }
        if let provider = sourceID.agentStorageProvider {
            guard agentSnapshot?.providers.contains(where: { summary in
                summary.provider == provider && summary.supportStatus != .notInstalled
            }) == true,
            agentSnapshot?.dataset(for: provider) != nil else {
                return .agentResultRequired(provider)
            }
        }
        return .available
    }
}

enum StorageSourceUsageOrdering {
    static func precedes(
        lhsID: StorageSourceID,
        lhsTitle: String,
        lhsBytes: UInt64,
        rhsID: StorageSourceID,
        rhsTitle: String,
        rhsBytes: UInt64
    ) -> Bool {
        if lhsBytes != rhsBytes { return lhsBytes > rhsBytes }
        let titleOrder = lhsTitle.localizedStandardCompare(rhsTitle)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhsID.rawValue < rhsID.rawValue
    }
}

enum StorageSourceDisplayOrdering {
    static func stabilized(
        current: [StorageSourceID],
        available: [StorageSourceID]
    ) -> [StorageSourceID] {
        let availableSet = Set(available)
        var seen = Set<StorageSourceID>()
        var result = current.filter {
            availableSet.contains($0) && seen.insert($0).inserted
        }
        result.append(contentsOf: available.filter { seen.insert($0).inserted })
        return result
    }
}

enum StorageVolumeLayoutPolicy {
    static func columnCount(
        width: CGFloat,
        itemCount: Int,
        minimumItemWidth: CGFloat,
        spacing: CGFloat
    ) -> Int {
        guard itemCount > 1 else { return max(0, itemCount) }
        let fittingColumns = max(
            1,
            Int((width + spacing) / (minimumItemWidth + spacing))
        )
        return min(itemCount, fittingColumns)
    }
}

enum StorageSourceReanalysisControlState: Equatable {
    case available
    case analyzing
    case hidden

    static func resolve(
        activityState: StorageSourceActivityPresentation.State,
        canReanalyze: Bool
    ) -> Self {
        if activityState == .active { return .analyzing }
        return canReanalyze ? .available : .hidden
    }
}

struct StorageSourceActivityPresentation: Equatable {
    enum State: Equatable {
        case ready
        case queued
        case active
        case complete
        case partial
    }

    let state: State
    let phaseTitle: String
    let workDetail: String
    let supportingDetail: String?
    let processedEntryCount: Int?
    let processedBytes: UInt64?

    static func completedComposition(for result: StorageSourceResult) -> String? {
        var seenTitles = Set<String>()
        let titles = result.components
            .sorted {
                if $0.allocatedBytes != $1.allocatedBytes {
                    return $0.allocatedBytes > $1.allocatedBytes
                }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            .compactMap { component -> String? in
                guard seenTitles.insert(component.title).inserted else { return nil }
                return L10n.text(component.title)
            }
            .prefix(3)

        guard !titles.isEmpty else { return nil }
        return titles.joined(separator: L10n.text("、"))
    }

    static func completedAgentComposition(
        for summary: AgentStorageProviderSummary
    ) -> String? {
        let categories = [
            (L10n.text("聊天与子代理"), summary.chatBytes),
            (L10n.text("工具全局数据"), summary.globalBytes),
            (L10n.text("未归属数据"), summary.unattributedBytes)
        ]
        .filter { $0.1 > 0 }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.localizedStandardCompare($1.0) == .orderedAscending
        }
        .map(\.0)

        guard !categories.isEmpty else { return nil }
        return categories.joined(separator: L10n.text("、"))
    }

    static func deferredWorkspace() -> Self {
        .init(
            state: .ready,
            phaseTitle: L10n.text("可进行仓库分析"),
            workDetail: L10n.text("进入详情后定位 Git 仓库与 Worktree"),
            supportingDetail: L10n.text("所有仓库统一归入这一项"),
            processedEntryCount: nil,
            processedBytes: nil
        )
    }

    static func workspace(
        candidate: StorageSourceCandidate,
        result: StorageSourceResult?
    ) -> Self {
        guard let result else { return deferredWorkspace() }
        return regular(
            candidate: candidate,
            result: result,
            progress: nil,
            isFullScanRunning: false
        )
    }

    static func regular(
        candidate: StorageSourceCandidate,
        result: StorageSourceResult?,
        progress: StorageScanProgress?,
        isFullScanRunning: Bool
    ) -> Self {
        if let progress, isFullScanRunning {
            return .init(
                state: progress.sourceCompleted ? .complete : .active,
                phaseTitle: progress.sourceCompleted
                    ? L10n.text("文件分配测量完成")
                    : L10n.text("正在测量文件分配"),
                workDetail: progress.currentWork.map(L10n.text)
                    ?? L10n.format("正在分析 %d 个已知位置", candidate.roots.count),
                supportingDetail: regularProgressDetail(progress),
                processedEntryCount: progress.sourceProcessedEntryCount,
                processedBytes: progress.sourceProcessedBytes
            )
        }
        if isFullScanRunning {
            return .init(
                state: .queued,
                phaseTitle: L10n.text("等待调度"),
                workDetail: L10n.format("已确认 %d 个已知位置", candidate.roots.count),
                supportingDetail: L10n.text("等待扫描器释放并发位置"),
                processedEntryCount: nil,
                processedBytes: nil
            )
        }
        if let result {
            return .init(
                state: result.isComplete ? .complete : .partial,
                phaseTitle: result.isComplete ? L10n.text("分析完成") : L10n.text("部分结果可用"),
                workDetail: StorageSourceDetailProfile.profile(for: candidate.id).headline,
                supportingDetail: regularResultDetail(result),
                processedEntryCount: result.entryCount,
                processedBytes: result.allocatedBytes
            )
        }
        return .init(
            state: .queued,
            phaseTitle: L10n.text("等待分析"),
            workDetail: L10n.format("已确认 %d 个已知位置", candidate.roots.count),
            supportingDetail: L10n.text("尚未读取文件分配信息"),
            processedEntryCount: nil,
            processedBytes: nil
        )
    }

    static func agent(
        provider: AgentStorageProvider,
        candidate: StorageSourceCandidate,
        summary: AgentStorageProviderSummary?,
        progress: AgentStorageScanProgress?,
        isScanning: Bool
    ) -> Self {
        if let progress, isScanning {
            return .init(
                state: agentProgressIsComplete(progress) ? .complete : .active,
                phaseTitle: agentPhaseTitle(progress),
                workDetail: agentWorkDetail(progress),
                supportingDetail: agentProgressDetail(progress),
                processedEntryCount: progress.completedCount > 0 ? progress.completedCount : nil,
                processedBytes: progress.processedBytes
            )
        }
        if isScanning {
            return .init(
                state: .queued,
                phaseTitle: L10n.text("等待调度"),
                workDetail: L10n.format("正在等待 %@ 深度分析", provider.displayName),
                supportingDetail: L10n.text("等待独立分析流水线开始"),
                processedEntryCount: nil,
                processedBytes: nil
            )
        }
        if let summary {
            return .init(
                state: .complete,
                phaseTitle: L10n.text("深度分析完成"),
                workDetail: L10n.text("聊天、全局与未归属空间已完成归因"),
                supportingDetail: L10n.format(
                    "%d 个数据位置 · %d 个主聊天 · %d 个子代理",
                    summary.sourceCount,
                    summary.threadCount,
                    summary.subagentCount
                ),
                processedEntryCount: summary.sourceCount,
                processedBytes: summary.exclusiveBytes
            )
        }
        return regular(
            candidate: candidate,
            result: nil,
            progress: nil,
            isFullScanRunning: isScanning
        )
    }

    private static func regularProgressDetail(_ progress: StorageScanProgress) -> String? {
        var details: [String] = []
        if let index = progress.currentWorkIndex,
           let total = progress.totalWorkCount,
           total > 0 {
            details.append(L10n.format("位置 %d / %d", min(index, total), total))
        }
        if progress.sourceProcessedEntryCount > 0 {
            details.append(L10n.format("已检查 %d 项", progress.sourceProcessedEntryCount))
        }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    private static func regularResultDetail(_ result: StorageSourceResult) -> String {
        let categoryCount = Set(result.components.map(\.title)).count
        if result.isComplete {
            return L10n.format(
                "%d 个聚合类别 · 可重建候选 %@",
                categoryCount,
                AgentStorageSizeFormatter.string(result.reclaimableCandidateBytes)
            )
        }
        return L10n.format(
            "%d 个聚合类别 · %d 个位置读取受限",
            categoryCount,
            result.skippedEntryCount
        )
    }

    private static func agentProgressDetail(_ progress: AgentStorageScanProgress) -> String? {
        var details: [String] = []
        if let total = progress.totalCount, total > 0 {
            details.append(L10n.format("进度 %d / %d", min(progress.completedCount, total), total))
        } else if progress.completedCount > 0 {
            details.append(L10n.format("已处理 %d 项", progress.completedCount))
        }
        if let bytes = progress.processedBytes, bytes > 0 {
            details.append(L10n.format("已测量 %@", AgentStorageSizeFormatter.string(bytes)))
        }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    private static func agentProgressIsComplete(_ progress: AgentStorageScanProgress) -> Bool {
        guard progress.phase == .organizingResults,
              let total = progress.totalCount else { return false }
        return progress.completedCount >= total
    }

    private static func agentPhaseTitle(_ progress: AgentStorageScanProgress) -> String {
        switch progress.phase {
        case .discoveringSources: L10n.text("正在定位数据位置")
        case .readingMetadata: L10n.text("正在读取聊天关系")
        case .measuringEntries: L10n.text("正在测量文件分配")
        case .validatingEntries: L10n.text("正在核对文件变化")
        case .attributingDatabase: L10n.text("正在进行日志数据库归因")
        case .organizingResults:
            agentProgressIsComplete(progress)
                ? L10n.text("深度分析完成")
                : L10n.text("正在整理空间归属")
        }
    }

    private static func agentWorkDetail(_ progress: AgentStorageScanProgress) -> String {
        switch progress.phase {
        case .discoveringSources:
            L10n.format("已发现 %d 个数据位置", progress.completedCount)
        case .readingMetadata:
            progress.activityCount.map { L10n.format("正在建立 %d 项聊天与子代理关系", $0) }
                ?? L10n.text("正在打开当前聊天索引")
        case .measuringEntries:
            L10n.format("已检查 %d 个文件与目录", progress.completedCount)
        case .validatingEntries:
            L10n.text("正在确认扫描期间发生的文件变化")
        case .attributingDatabase:
            switch progress.databaseStage {
            case .readingRecords:
                L10n.format("已读取 %d 条日志记录", progress.completedCount)
            case .mappingRecords:
                L10n.format("正在匹配 %d 条日志的聊天归属", progress.completedCount)
            case .preparing, nil:
                L10n.text("正在确认数据库结构与只读快照")
            }
        case .organizingResults:
            L10n.text("正在整理聊天、全局与未归属空间")
        }
    }
}

struct StorageSourceDetailProfile {
    struct OfficialAction {
        let title: String
        let url: URL
    }

    let headline: String
    let summary: String
    let compositionTitle: String
    let compositionDetail: String
    let managementTitle: String
    let managementDetail: String
    let officialAction: OfficialAction?

    static func profile(for sourceID: StorageSourceID) -> Self {
        switch sourceID {
        case .chrome:
            .init(
                headline: L10n.text("区分缓存、站点数据与浏览器档案"),
                summary: L10n.text("Chrome 的占用不等同于缓存。可重建缓存、扩展与离线站点数据、登录与浏览器档案需要分开判断。"),
                compositionTitle: L10n.text("浏览器空间构成"),
                compositionDetail: L10n.text("按数据用途聚合所有已发现的 Chrome 渠道与档案，不展开浏览记录或具体站点。"),
                managementTitle: L10n.text("在 Chrome 中管理"),
                managementDetail: L10n.text("优先在 Chrome 设置中按站点检查空间。清除缓存通常可恢复；站点离线数据、扩展和档案数据可能包含登录状态与个人配置。"),
                officialAction: URL(string: "chrome://settings/content/all").map {
                    .init(title: L10n.text("打开 Chrome 站点存储"), url: $0)
                }
            )
        case .go:
            .init(
                headline: L10n.text("看清构建缓存、模块缓存与已安装工具"),
                summary: L10n.text("Go 的空间主要来自可重建的编译结果、共享模块内容和 GOPATH 中安装的命令。这里按用途汇总，不逐个展开模块或文件。"),
                compositionTitle: L10n.text("Go 工具链空间"),
                compositionDetail: L10n.text("Go 使用目录级物理分配汇总：构建缓存、模块下载缓存、已解压模块和已安装工具分别测量，不在界面中逐项建立文件模型。"),
                managementTitle: L10n.text("理解清理边界"),
                managementDetail: L10n.text("构建缓存可单独勾选并在确认后处理；模块缓存包含下载副本与已解压源码，必须整体理解其重建成本后再决定。"),
                officialAction: nil
            )
        case .npm:
            packageManagerProfile(
                headline: L10n.text("分开识别内容缓存、npx 临时安装与日志"),
                summary: L10n.text("npm 的全局缓存采用内容寻址存储，npx 还会留下临时安装。它们不同于项目中的 node_modules。"),
                detail: L10n.text("缓存通常可重新下载；npx 临时安装可重新创建；调试日志用于排查失败。项目依赖不在这里逐个展开。")
            )
        case .pnpm:
            packageManagerProfile(
                headline: L10n.text("识别跨项目复用的共享包存储"),
                summary: L10n.text("pnpm store 会被多个项目共同引用，磁盘占用不能简单等同于某个项目的可释放空间。"),
                detail: L10n.text("共享包内容的重建需要重新下载，并可能影响多个工作区；索引元数据成本较低。本页不会把共享内容重复计入每个项目。")
            )
        case .bun:
            packageManagerProfile(
                headline: L10n.text("区分下载缓存与全局安装"),
                summary: L10n.text("Bun 同时保存可重建的包缓存与用户主动安装的全局命令，两者不应采用相同的处理方式。"),
                detail: L10n.text("缓存包可重新下载，并可在资源树中勾选后处理；全局包代表已安装工具，移除后相关命令将不可用。")
            )
        case .pip:
            packageManagerProfile(
                headline: L10n.text("区分下载响应、Wheel 与索引元数据"),
                summary: L10n.text("pip 缓存主要用于避免重复下载和构建，不代表当前 Python 环境中已经安装的包。"),
                detail: L10n.text("HTTP 缓存和 Wheel 缓存均可重建，但下一次安装可能需要重新下载或编译；虚拟环境在工作区分析中单独汇总。")
            )
        case .xcode:
            .init(
                headline: L10n.text("区分构建产物、源码包与开发归档"),
                summary: L10n.text("Xcode 的 DerivedData 多数可重建，但归档可能包含唯一的发布记录与调试符号，不能按缓存对待。"),
                compositionTitle: L10n.text("Xcode 开发资产"),
                compositionDetail: L10n.text("构建索引、中间产物、产品、源码包检出与归档按用途聚合，不展开项目文件。"),
                managementTitle: L10n.text("保留发布资产"),
                managementDetail: L10n.text("构建缓存可由 Xcode 重建；源码包重新获取需要网络；归档可能用于崩溃符号化与重新分发，应在 Xcode Organizer 中确认后管理。"),
                officialAction: nil
            )
        case .vscode:
            .init(
                headline: L10n.text("区分编辑器缓存、扩展与工作区状态"),
                summary: L10n.text("VS Code 的占用不仅来自缓存，还包含已安装扩展、用户设置、工作区状态、本地历史与未保存文件备份。"),
                compositionTitle: L10n.text("VS Code 空间构成"),
                compositionDetail: L10n.text("按编辑器缓存、扩展安装包缓存、已安装扩展、用户与工作区状态、日志和备份分别统计。"),
                managementTitle: L10n.text("只清理可重建内容"),
                managementDetail: L10n.text("缓存、日志与崩溃报告可以重新生成；扩展、设置、工作区状态、本地历史和未保存备份始终保持受保护。"),
                officialAction: nil
            )
        case .simulators:
            .init(
                headline: L10n.text("分辨运行时、设备与模拟器应用数据"),
                summary: L10n.text("Simulator 与 Simulator Runtime 是两类资产：前者保存设备和测试应用数据，后者是可重新下载的系统镜像；共享缓存与待删除数据也会单独统计。"),
                compositionTitle: L10n.text("模拟器资产"),
                compositionDetail: L10n.text("按设备、应用数据、Runtime 镜像、共享缓存和后台待删数据聚合。只统计 Runtime 的宿主机 backing storage，不重复统计只读挂载卷。"),
                managementTitle: L10n.text("通过开发工具管理"),
                managementDetail: L10n.text("运行时应在 Xcode 的平台设置中管理；设备与应用数据应先确认测试状态。删除设备会同时移除其中的应用和数据。"),
                officialAction: nil
            )
        case .docker:
            .init(
                headline: L10n.text("跟随 Docker 配置定位真实虚拟磁盘"),
                summary: L10n.text("同时测量 Docker Desktop 的宿主机物理占用；Engine 可连接时，再读取镜像、容器、Volume 与构建缓存的官方容量报告。"),
                compositionTitle: L10n.text("Docker 空间构成"),
                compositionDetail: L10n.text("宿主机物理分配与 Engine 对象容量分开展示。镜像按 ID 去重，并区分独占、共享与总大小，避免多标签重复计数。"),
                managementTitle: L10n.text("按引用关系安全清理"),
                managementDetail: L10n.text("零容器引用的镜像和 Volume 可单独勾选；删除前会再次查询 Docker Engine。悬空镜像可默认安全清理，Volume 可能保存持久数据，始终由用户手动选择。"),
                officialAction: nil
            )
        case .podman:
            containerProfile(
                headline: L10n.text("区分虚拟机、容器层与持久卷"),
                summary: L10n.text("Podman 的机器磁盘、镜像与容器层、命名卷具有不同生命周期，命名卷尤其可能保存业务数据。"),
                detail: L10n.text("虚拟机和容器层需要由 Podman 了解内部引用关系；命名卷属于持久数据。本页不会依据文件树猜测可删除对象。")
            )
        case .workspace:
            .init(
                headline: L10n.text("聚合依赖、环境与框架缓存"),
                summary: L10n.text("工作区分析只区分项目文件、依赖目录、Python 环境和框架缓存，不读取源码内容，也不展开每个文件。"),
                compositionTitle: L10n.text("工作区空间结构"),
                compositionDetail: L10n.text("项目文件始终视为受保护数据；依赖和环境可能重建，但成本取决于锁文件、网络与本地工具链。"),
                managementTitle: L10n.text("在项目上下文中判断"),
                managementDetail: L10n.text("主仓库与 worktree 会按关系归组。当前仓库保持锁定；其他仓库只有在勾选并二次确认后才会移入废纸篓。"),
                officialAction: nil
            )
        case .codex, .claude:
            .init(
                headline: L10n.text("聊天与子代理分析"),
                summary: L10n.text("按聊天、线程族与子代理关系分析占用。"),
                compositionTitle: L10n.text("聊天与子代理"),
                compositionDetail: "",
                managementTitle: "",
                managementDetail: "",
                officialAction: nil
            )
        default:
            .init(
                headline: L10n.text("理解这个来源的空间构成"),
                summary: L10n.text("按用途聚合已测得的本机空间，不展开文件内容。"),
                compositionTitle: L10n.text("空间构成"),
                compositionDetail: L10n.text("仅显示已知位置的文件分配占用。"),
                managementTitle: L10n.text("分析边界"),
                managementDetail: L10n.text("分析阶段始终只读；只有带复选框的已验证资源可进入批量清理确认。"),
                officialAction: nil
            )
        }
    }

    func categoryDescription(_ title: String) -> String {
        switch title {
        case "浏览器缓存", "代码缓存", "GPU 与着色器缓存": L10n.text("可由浏览器重新生成，不包含浏览历史本身。")
        case "站点离线数据": L10n.text("网站为离线使用与本地功能保存的数据，清除后可能需要重新登录或同步。")
        case "扩展": L10n.text("已安装扩展及其状态，应从 Chrome 扩展管理器确认。")
        case "浏览器档案数据", "受保护浏览器数据": L10n.text("包含档案配置或账户相关状态，按受保护数据处理。")
        case "崩溃报告": L10n.text("浏览器异常退出生成的诊断材料，可重建但可能用于问题排查。")
        case "构建缓存": L10n.text("Go 编译结果缓存，可重建但会增加下一次构建时间。")
        case "模块下载缓存": L10n.text("模块代理下载内容，可重新下载。")
        case "已解压模块": L10n.text("多个 Go 项目可共享的模块源码副本。")
        case "已安装工具": L10n.text("GOPATH 中已安装的命令，移除后工具将不可用。")
        case "内容寻址缓存": L10n.text("npm 校验过的共享包内容，可重新下载并重新填充。")
        case "npx 临时安装": L10n.text("npx 为临时执行保存的包环境，再次使用时可重新创建。")
        case "调试日志": L10n.text("npm 命令失败与诊断记录，仅在排查问题时有保留价值。")
        case "共享包内容": L10n.text("pnpm 跨项目复用的包文件，清理会影响多个工作区的后续安装。")
        case "包索引元数据": L10n.text("pnpm 用于定位共享包内容的索引，可由工具重新生成。")
        case "全局包": L10n.text("用户主动安装的全局命令与运行环境，不属于普通下载缓存。")
        case "缓存包", "包缓存": L10n.text("包管理器保存的下载内容，可重建但会产生网络与安装成本。")
        case "HTTP 下载缓存": L10n.text("pip 保存的下载响应，可重新获取，不代表环境中已安装的包。")
        case "已构建 Wheel 缓存": L10n.text("pip 已构建的 Wheel，可重建但可能再次消耗编译时间。")
        case "索引检查元数据": L10n.text("pip 的版本与索引检查状态，占用较小且可重新生成。")
        case "源码包检出": L10n.text("Swift Package 依赖源码，重新获取需要网络和依赖解析。")
        case "构建索引": L10n.text("Xcode 代码索引，可重建但会暂时影响搜索与补全。")
        case "构建中间产物": L10n.text("编译产生的中间文件，可重建但会增加下一次构建时间。")
        case "构建产品": L10n.text("当前项目的构建输出，可能包含仍需测试或分发的产物。")
        case "归档": L10n.text("发布归档与调试符号，可能无法从构建缓存恢复。")
        case "编辑器缓存": L10n.text("VS Code 可重新生成的编辑器与 Web 缓存，不包含用户设置和工作区状态。")
        case "图形缓存": L10n.text("Electron 图形管线生成的 GPU、Dawn 与着色器缓存，可重新创建。")
        case "扩展安装包缓存": L10n.text("已下载的扩展安装包副本；不会移除当前已经安装的扩展。")
        case "编辑器日志": L10n.text("VS Code 运行与扩展宿主日志，仅在排查近期问题时有保留价值。")
        case "更新缓存": L10n.text("VS Code 更新器留下的下载与暂存内容，可由更新器重新获取。")
        case "已安装扩展": L10n.text("用户主动安装的扩展及其程序文件，移除后对应开发能力将不可用。")
        case "编辑器 CLI 与配置": L10n.text("VS Code 命令行组件与启动配置，不属于缓存。")
        case "工作区状态": L10n.text("每个工作区的编辑器状态、扩展状态与会话信息，按用户数据保护。")
        case "用户设置与扩展状态": L10n.text("包含设置、快捷键、代码片段以及扩展的全局状态。")
        case "本地历史与未保存备份": L10n.text("可能包含尚未写回项目的内容或本地编辑历史，始终受保护。")
        case "扩展与 Web 状态": L10n.text("扩展 WebView、认证和本地会话使用的数据，清除可能导致状态丢失。")
        case "编辑器状态数据", "编辑器用户与工作区数据": L10n.text("VS Code 保存的运行状态和用户数据，未验证为缓存时一律受保护。")
        case "已安装扩展与 CLI": L10n.text("已安装扩展、命令行组件与启动配置，不作为普通缓存处理。")
        case "模拟器运行时": L10n.text("可从 Xcode 重新下载的系统运行时，体积大且重建依赖网络。")
        case "模拟器设备": L10n.text("模拟设备的状态与配置，删除设备会连同其中数据一起移除。")
        case "模拟器应用数据": L10n.text("测试应用在模拟器中的文档、数据库与状态，应按用户数据判断。")
        case "模拟器缓存": L10n.text("模拟器与 CoreSimulator 生成的缓存，可重新创建。")
        case "模拟器待删除数据": L10n.text("CoreSimulator 已安排后台移除的残留数据，通常会由系统继续清理。")
        case "Docker 虚拟磁盘": L10n.text("承载镜像、容器、卷与构建缓存的整体磁盘，文件大小不等于可回收量。")
        case "Docker 磁盘维护副本": L10n.text("磁盘检查前后保留的虚拟磁盘副本，可能用于恢复，确认 Docker 正常运行后再决定是否处理。")
        case "Docker Desktop 状态": L10n.text("Docker Desktop 的配置与运行状态，应通过官方界面管理。")
        case "容器日志": L10n.text("容器运行日志可能用于故障排查，应结合具体容器状态判断。")
        case "Podman 虚拟机": L10n.text("Podman machine 的系统磁盘与运行环境，应由 Podman 管理生命周期。")
        case "镜像与容器层": L10n.text("镜像和容器共享的文件层，必须由容器引擎核对引用关系。")
        case "命名卷": L10n.text("容器持久数据，不应作为普通缓存处理。")
        case "项目文件": L10n.text("用户项目内容，始终受保护。")
        case "依赖目录": L10n.text("项目安装的依赖副本，能否重建取决于锁文件与包源。")
        case "Python 环境": L10n.text("项目解释器与已安装包环境，重建成本取决于依赖声明和本地工具链。")
        case "框架缓存": L10n.text("前端框架与构建工具生成的项目缓存，通常可重建。")
        case "代码仓库内容": L10n.text("主仓库中的源码、版本历史与项目资产，按受保护数据处理。")
        case "Worktree 内容": L10n.text("共享主仓库 Git 数据但拥有独立工作目录与分支状态。")
        default: riskFallbackDescription
        }
    }

    private var riskFallbackDescription: String {
        L10n.text("按用途聚合的空间类别；请结合右侧风险标记判断重建成本。")
    }

    private static func packageManagerProfile(headline: String, summary: String, detail: String) -> Self {
        .init(
            headline: headline,
            summary: summary,
            compositionTitle: L10n.text("包管理器空间"),
            compositionDetail: L10n.text("按缓存、共享内容、临时安装或全局工具聚合，不展开每个包和文件。"),
            managementTitle: L10n.text("重建成本与作用域"),
            managementDetail: detail,
            officialAction: nil
        )
    }

    private static func containerProfile(headline: String, summary: String, detail: String) -> Self {
        .init(
            headline: headline,
            summary: summary,
            compositionTitle: L10n.text("容器运行环境"),
            compositionDetail: L10n.text("展示宿主机可验证的聚合占用，不把虚拟磁盘分配量包装成可回收空间。"),
            managementTitle: L10n.text("使用官方工具确认"),
            managementDetail: detail,
            officialAction: nil
        )
    }
}
