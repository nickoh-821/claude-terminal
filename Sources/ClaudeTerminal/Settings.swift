import Foundation

/// User preferences, read from UserDefaults. Set them with
/// `defaults write io.github.nickoh-821.claudeterminal <key> …`.
enum Settings {
    /// Where "New Project…" creates folders (`ProjectsFolder`, default ~/Work).
    static var projectsFolder: String {
        let raw = UserDefaults.standard.string(forKey: "ProjectsFolder") ?? "~/Work"
        return (raw as NSString).expandingTildeInPath
    }
}
