import Foundation
import FindDiskKillerCore

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case brazilianPortuguese = "pt-BR"
    case russian = "ru"

    var id: String { rawValue }

    var localeIdentifier: String {
        switch self {
        case .system: L10n.preferredLanguage.localeIdentifier
        default: rawValue
        }
    }

    var localizedName: String {
        switch self {
        case .system: L10n.text("跟随系统")
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .german: "Deutsch"
        case .french: "Français"
        case .spanish: "Español"
        case .brazilianPortuguese: "Português (Brasil)"
        case .russian: "Русский"
        }
    }
}

extension SampleRange {
    var localizedTitle: String { L10n.text(rawValue) }
}

extension HistoryRetention {
    var localizedTitle: String {
        switch self {
        case .sevenDays: L10n.text("7 天")
        case .thirtyDays: L10n.text("30 天")
        case .oneYear: L10n.text("1 年")
        }
    }

    var localizedAnalysisTitle: String {
        switch self {
        case .sevenDays: L10n.text("近 7 天分析")
        case .thirtyDays: L10n.text("近 30 天分析")
        case .oneYear: L10n.text("近 1 年分析")
        }
    }
}

extension ProcessActivity {
    var localizedDisplayName: String {
        let marker = "（可能关联）"
        guard name.hasSuffix(marker) else { return name }
        return String(name.dropLast(marker.count)) + L10n.text(marker)
    }
}

enum L10n {
    static var selectedLanguage: AppLanguage {
        let rawValue = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    static var preferredLanguage: AppLanguage {
        let identifier = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if identifier.hasPrefix("zh-hant") || identifier.hasPrefix("zh-tw")
            || identifier.hasPrefix("zh-hk") { return .traditionalChinese }
        if identifier.hasPrefix("zh") { return .simplifiedChinese }
        if identifier.hasPrefix("ja") { return .japanese }
        if identifier.hasPrefix("ko") { return .korean }
        if identifier.hasPrefix("de") { return .german }
        if identifier.hasPrefix("fr") { return .french }
        if identifier.hasPrefix("es") { return .spanish }
        if identifier.hasPrefix("pt") { return .brazilianPortuguese }
        if identifier.hasPrefix("ru") { return .russian }
        return .english
    }

    static var effectiveLanguage: AppLanguage {
        selectedLanguage == .system ? preferredLanguage : selectedLanguage
    }

    static func text(_ key: String) -> String {
        let localized = languageBundle.localizedString(forKey: key, value: key, table: nil)
        guard localized == key, effectiveLanguage != .simplifiedChinese else {
            return localized
        }
        return historyEnglishFallbacks[key] ?? localized
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: text(key),
            locale: Locale(identifier: effectiveLanguage.localeIdentifier),
            arguments: arguments
        )
    }

    static func date(
        _ value: Date,
        date: Date.FormatStyle.DateStyle,
        time: Date.FormatStyle.TimeStyle
    ) -> String {
        value.formatted(
            Date.FormatStyle(date: date, time: time)
                .locale(Locale(identifier: effectiveLanguage.localeIdentifier))
        )
    }

    private static var languageBundle: Bundle {
        languageBundles[effectiveLanguage.rawValue.lowercased()] ?? AppResourceBundle.value
    }

    private static let languageBundles: [String: Bundle] = {
        Dictionary(uniqueKeysWithValues: AppLanguage.allCases.compactMap { language in
            guard language != .system else { return nil }
            let resourceName = language.rawValue.lowercased()
            guard let path = AppResourceBundle.value.path(forResource: resourceName, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                return nil
            }
            return (resourceName, bundle)
        })
    }()

    // New history surfaces fall back to English until each existing localization
    // receives a native translation; this avoids mixed Chinese UI in non-Chinese locales.
    private static let historyEnglishFallbacks: [String: String] = [
        "7 天": "7 Days",
        "30 天": "30 Days",
        "1 年": "1 Year",
        "近 7 天分析": "7-Day Analysis",
        "近 30 天分析": "30-Day Analysis",
        "近 1 年分析": "1-Year Analysis",
        "上一周期数据不足；当前结论仅基于已覆盖时间，不会用零值补齐缺口。": "The previous period has insufficient data. Findings use only covered time and never fill gaps with zeroes.",
        "不会保存文件路径、PID、逐秒样本或深度追踪记录。": "File paths, PIDs, per-second samples, and deep trace records are not saved.",
        "主要应用": "Leading Applications",
        "导出包含聚合资源统计和应用名称；请选择可信的位置。": "The export contains aggregate resource statistics and application names. Choose a trusted location.",
        "仅在本机保存聚合数据；每分钟批量写入一次，分钟明细保留 24 小时。": "Aggregated data stays on this Mac and is written once per minute. Minute detail is kept for 24 hours.",
        "保存应用级活动": "Save Application Activity",
        "保存监测历史": "Save Monitoring History",
        "保留时间": "Retention",
        "写入 %@": "Write %@",
        "写入占比": "Write Share",
        "峰值 CPU": "Peak CPU",
        "数据覆盖": "Data Coverage",
        "数据覆盖 %.0f%%，共 %d 个数据点": "Data coverage %.0f%% across %d data points",
        "刷新分析": "Refresh Analysis",
        "历史保存正常": "History Saving Normally",
        "历史保存已关闭": "History Saving Off",
        "历史数据库不可用": "History Database Unavailable",
        "取消": "Cancel",
        "周期观察": "Period Findings",
        "在设置中开启后，聚合数据将每分钟保存一次且只留在本机。": "Enable history in Settings to save local aggregate data once per minute.",
        "完成第一个分钟汇总后，这里会出现趋势和应用排名。": "Trends and application rankings appear after the first minute is summarized.",
        "实时会话": "Live Session",
        "实时曲线仍只保留在内存中，退出应用后自动清除。": "Live charts remain in memory and are cleared when the app quits.",
        "尚未保存": "Not Saved Yet",
        "尚未保存监测历史": "No Monitoring History Yet",
        "已暂停历史保存": "History Saving Paused",
        "平均 CPU": "Average CPU",
        "当前仅保存整机与设备聚合。": "Only system and device aggregates are currently saved.",
        "所有历史分析数据和应用排名将被永久删除，实时监测不受影响。": "All history data and application rankings will be permanently deleted. Live monitoring is unaffected.",
        "已有历史可在停止保存后继续查看；删除后无法恢复。": "Saved history remains available after recording stops. Deletion cannot be undone.",
        "打开数据设置": "Open Data Settings",
        "在 Finder 中显示数据文件": "Show Data File in Finder",
        "历史分析": "History",
        "导出 CSV": "Export CSV",
        "导出 PDF": "Export PDF",
        "导出历史分析": "Export History",
        "无法导出历史分析": "Unable to Export History",
        "趋势指标": "Trend Metric",
        "CPU 活动趋势": "CPU Activity Trend",
        "网络活动趋势": "Network Activity Trend",
        "连续区间": "Continuous Interval",
        "接收": "Received",
        "发送": "Sent",
        "缺失时段会断开显示，不会按零值补齐。": "Missing intervals are shown as gaps and are never filled with zeroes.",
        "当前周期数据覆盖不足 70%，暂不生成与上一周期的比较结论。": "Coverage is below 70%, so no comparison with the previous period is generated.",
        "好": "OK",
        "分析周期": "Analysis Period",
        "指标": "Metric",
        "按写入总量排序": "Sorted by Total Writes",
        "接近上限": "Nearing Limit",
        "接近空间上限": "Nearing Storage Limit",
        "数据覆盖 %.0f%%": "Data Coverage %.0f%%",
        "无法读取历史分析": "Unable to Load History",
        "最大占用": "Maximum Storage",
        "最近保存": "Last Saved",
        "本地占用": "Local Storage",
        "本地空间": "Local Storage",
        "正在优化 %.0f%%": "Optimizing %.0f%%",
        "正在优化历史": "Optimizing History",
        "正在加载历史分析": "Loading History",
        "正在积累历史数据": "Building History",
        "正常": "Normal",
        "清除历史": "Clear History",
        "清除实时会话数据": "Clear Live Session Data",
        "清除已保存历史": "Clear Saved History",
        "清除已保存历史？": "Clear Saved History?",
        "仅停止保存": "Stop Saving Only",
        "停止保存监测历史？": "Stop Saving Monitoring History?",
        "停止并删除已有历史": "Stop and Delete Saved History",
        "物理写入": "Physical Writes",
        "物理写入与上一周期基本持平。": "Physical writes are essentially unchanged from the previous period.",
        "物理写入较上一周期减少 %.0f%%。": "Physical writes decreased %.0f%% from the previous period.",
        "物理写入较上一周期增加 %.0f%%。": "Physical writes increased %.0f%% from the previous period.",
        "物理读取": "Physical Reads",
        "登录后打开主窗口": "Open Main Window After Login",
        "监测历史": "Monitoring History",
        "磁盘活动趋势": "Disk Activity Trend",
        "等待首个分钟汇总": "Waiting for First Minute Summary",
        "缩短保留时间？": "Shorten Retention?",
        "缩短并删除": "Shorten and Delete",
        "网络传输": "Network Transfer",
        "读取 %@": "Read %@",
        "达到预算并暂停": "Budget Reached and Paused",
        "这个周期还没有应用级活动。": "There is no application activity for this period yet.",
        "选定时间": "Selected Time",
        "部分明细已精简": "Some Detail Was Compacted",
        "降低并优化": "Lower and Optimize",
        "降低最大占用？": "Lower Maximum Storage?",
        "预计占用": "Estimated Storage",
        "其他": "Other"
    ]
}

enum AppResourceBundle {
    static var value: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        .main
        #endif
    }
}
