import Darwin
import Foundation

enum RepositoryAccessAuthorization {
    static func hasFullDiskAccess(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let relativePaths = [
            ".Trash",
            "Library/Safari",
            "Library/Mail",
            "Library/Calendars",
            "Library/HomeKit",
            "Library/Messages",
            "Library/Safari/History.db",
            "Library/Messages/chat.db"
        ]
        for relativePath in relativePaths {
            let path = homeDirectory.appending(path: relativePath).path
            var value = stat()
            guard lstat(path, &value) == 0 else { continue }
            let directoryFlag = (value.st_mode & S_IFMT) == S_IFDIR ? O_DIRECTORY : 0
            let descriptor = open(path, O_RDONLY | O_CLOEXEC | directoryFlag)
            if descriptor >= 0 {
                close(descriptor)
                return true
            }
            if errno == EACCES || errno == EPERM { return false }
        }
        return false
    }

    static var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }
}
