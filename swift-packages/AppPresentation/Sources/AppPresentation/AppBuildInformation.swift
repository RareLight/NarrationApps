import SwiftUI

/// Build metadata stamped into each app's generated Info.plist by
/// scripts/generate-app-info.sh: marketing version, commit-count build number,
/// full HEAD revision and a worktree-modified flag.
public struct AppBuildInformation: Sendable, Equatable {
    public let version: String
    public let build: String
    public let revision: String
    public let modified: Bool

    public init(version: String, build: String, revision: String, modified: Bool) {
        self.version = version
        self.build = build
        self.revision = revision
        self.modified = modified
    }

    public init(info: [String: Any]) {
        version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        build = info["CFBundleVersion"] as? String ?? "unknown"
        revision = info["NarrationAppsGitRevision"] as? String ?? ""
        modified = info["NarrationAppsSourceModified"] as? Bool ?? false
    }

    public init(bundle: Bundle = .main) {
        self.init(info: bundle.infoDictionary ?? [:])
    }

    /// "71, 431413c modified" - build number plus the short revision and the
    /// dirty-worktree marker, used beside the marketing version in About.
    public var buildDescription: String {
        var text = build
        if !revision.isEmpty { text += ", \(String(revision.prefix(7)))" }
        if modified { text += " modified" }
        return text
    }

    /// About-panel display values derived from the generated build metadata:
    /// the marketing version and the commit-based build description.
    public static func aboutDisplay(_ info: AppBuildInformation) -> (version: String, build: String) {
        (version: info.version, build: info.buildDescription)
    }
}

/// Replaces the standard About menu command with one that opens the native
/// About panel, which shows the generated version/build metadata.
public struct AppVersionCommands: Commands {
    public init() {}
    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "App")") {
                let info = AppBuildInformation(bundle: .main)
                NSApplication.shared.orderFrontStandardAboutPanel(options: [
                    NSApplication.AboutPanelOptionKey.applicationVersion: AppBuildInformation.aboutDisplay(info).version,
                    NSApplication.AboutPanelOptionKey.version: AppBuildInformation.aboutDisplay(info).build])
            }
        }
    }
}
