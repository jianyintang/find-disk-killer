import SwiftUI

struct UpdaterSettingsSection: View {
    let updates: UpdateCoordinator

    var body: some View {
        Form {
            Section(L10n.text("软件更新")) {
                Toggle(
                    L10n.text("自动检查更新"),
                    isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.automaticallyChecksForUpdates = $0 }
                    )
                )
                .disabled(!updates.isConfigured)

                Text(L10n.text("每天最多检查一次；不会上传监测数据。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent(L10n.text("当前版本"), value: versionDescription)

                if let reason = updates.blockReason {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text(reason)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if updates.blockAction == .openInstallationLocation {
                            Button(L10n.text("在 Finder 中打开")) {
                                updates.openInstallationLocation()
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button(action: updates.checkForUpdates) {
                        if updates.isChecking {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text(L10n.text("正在检查"))
                            }
                        } else {
                            Label(
                                L10n.text("检查更新…"),
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                        }
                    }
                    .disabled(!updates.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "-"
        return L10n.format("版本 %@（%@）", version, build)
    }
}
