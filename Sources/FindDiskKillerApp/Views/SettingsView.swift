import FindDiskKillerCore
import SwiftUI

struct SettingsView: View {
    let store: MonitorStore
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showRateInMenuBar") private var showRateInMenuBar = true
    @AppStorage("sampleInterval") private var sampleInterval = 1.0
    @AppStorage("historyHours") private var historyHours = 24
    @AppStorage("retainFullPaths") private var retainFullPaths = false
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue

    var body: some View {
        TabView {
            Form {
                LabeledContent(L10n.text("语言")) {
                    Picker(L10n.text("语言"), selection: $appLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.localizedName).tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                Toggle(L10n.text("登录时启动"), isOn: $launchAtLogin)
                Toggle(L10n.text("在菜单栏显示写入速率"), isOn: $showRateInMenuBar)
                LabeledContent(L10n.text("采样间隔")) {
                    Picker(L10n.text("采样间隔"), selection: $sampleInterval) {
                        Text(L10n.text("1 秒")).tag(1.0)
                        Text(L10n.text("2 秒")).tag(2.0)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label(L10n.text("通用"), systemImage: "gear") }

            Form {
                LabeledContent(L10n.text("普通历史")) {
                    Picker(L10n.text("普通历史"), selection: $historyHours) {
                        Text(L10n.text("6 小时")).tag(6)
                        Text(L10n.text("24 小时")).tag(24)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                Toggle(L10n.text("诊断记录保留完整路径"), isOn: $retainFullPaths)
                Button(L10n.text("立即清除历史"), role: .destructive) {}
            }
            .formStyle(.grouped)
            .tabItem { Label(L10n.text("数据与隐私"), systemImage: "hand.raised") }

        }
        .scenePadding()
        .frame(width: 520, height: 330)
        .task { store.samplingInterval = sampleInterval }
        .onChange(of: sampleInterval) { _, newValue in
            store.samplingInterval = newValue
        }
    }
}
