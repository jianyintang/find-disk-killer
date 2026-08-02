import SwiftUI

enum AppVersionDescription {
    static var localized: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "-"
        return L10n.format("版本 %@（%@）", version, build)
    }
}

struct AutomaticUpdateSettingsSection: View {
    let updates: UpdateCoordinator

    var body: some View {
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
        }
    }
}

struct AboutUpdateSection: View {
    let updates: UpdateCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("软件更新"))
                .font(.headline)

            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("当前版本"))
                            .font(.callout.weight(.medium))
                        Text(AppVersionDescription.localized)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 20)

                    Button(action: updates.checkForUpdates) {
                        if updates.isChecking {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text(L10n.text("正在检查"))
                            }
                        } else {
                            Text(L10n.text("检查更新…"))
                        }
                    }
                    .buttonStyle(AppActionButtonStyle(kind: .primary, size: .compact))
                    .disabled(!updates.canCheckForUpdates)
                }
                .padding(16)

                if let reason = updates.blockReason {
                    Divider()
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if updates.blockAction == .openInstallationLocation {
                            Button(L10n.text("在 Finder 中打开")) {
                                updates.openInstallationLocation()
                            }
                            .buttonStyle(AppActionButtonStyle(kind: .secondary, size: .compact))
                        }
                    }
                    .padding(16)
                }
            }
            .background(Color.secondary.opacity(0.035))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 0.5)
            }
        }
    }
}
