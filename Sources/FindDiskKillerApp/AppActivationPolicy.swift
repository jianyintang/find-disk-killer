import AppKit
import Foundation

/// Controls whether the app runs as a regular Dock app or menu-bar-only accessory.
enum AppActivationPolicy {
    static let menuBarOnlyModeKey = "menuBarOnlyMode"

    static func isMenuBarOnlyMode(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: menuBarOnlyModeKey)
    }

    /// Preferred policy for normal operation and when presenting the main window.
    /// Menu-bar-only mode stays `.accessory` so the Dock icon never appears.
    @MainActor
    static func preferred(
        defaults: UserDefaults = .standard
    ) -> NSApplication.ActivationPolicy {
        isMenuBarOnlyMode(defaults: defaults) ? .accessory : .regular
    }

    @MainActor
    static func applyPreferred(
        defaults: UserDefaults = .standard,
        application: NSApplication = .shared
    ) {
        application.setActivationPolicy(preferred(defaults: defaults))
    }

    /// Configures activation policy at launch and reports whether the main window should stay visible.
    @MainActor
    static func configureLaunch(
        isDefaultLaunch: Bool,
        forcesMainWindow: Bool,
        defaults: UserDefaults = .standard,
        application: NSApplication = .shared
    ) -> Bool {
        let openMainWindowAtLogin = defaults.bool(forKey: "openMainWindowAtLogin")
        let menuBarOnly = isMenuBarOnlyMode(defaults: defaults)

        if menuBarOnly {
            application.setActivationPolicy(.accessory)
            let shouldShowWindow = forcesMainWindow
                || (!isDefaultLaunch && openMainWindowAtLogin)
            if !shouldShowWindow {
                DispatchQueue.main.async {
                    application.windows.forEach { $0.orderOut(nil) }
                }
            }
            return shouldShowWindow
        }

        if !forcesMainWindow && !isDefaultLaunch && !openMainWindowAtLogin {
            application.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                application.windows.forEach { $0.orderOut(nil) }
            }
            return false
        }

        application.setActivationPolicy(.regular)
        return forcesMainWindow || isDefaultLaunch || openMainWindowAtLogin
    }
}
