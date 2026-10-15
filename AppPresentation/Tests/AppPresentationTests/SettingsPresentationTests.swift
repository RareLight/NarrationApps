import SwiftUI
import Testing
@testable import AppPresentation

private enum FixturePane: String, SettingsPane {
    case general, pronunciation, publishing, troubleshooting
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var systemImage: String { "gearshape" }
    var help: String { title }
}

@Test @MainActor func sharedSettingsSupportAdaptiveNavigationAndInertControls() {
    #expect(SettingsNavigation<FixturePane>.idealWidth == 392)
    for pane in FixturePane.allCases {
        _ = SettingsNavigation(selection: .constant(pane)).body
    }
    var helpOpened = false
    _ = SettingsSectionHeader(title: "Synthetic", explanation: "Brief help.", moreHelp: { helpOpened = true }).body
    _ = AppearanceSettingsSection(textSize: .constant(.init(percent: 200))).body
    _ = SettingsNotice(message: "Synthetic notice").body
    #expect(!helpOpened)
}
