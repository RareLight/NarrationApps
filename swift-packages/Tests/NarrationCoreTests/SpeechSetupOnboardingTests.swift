import XCTest
@testable import NarrationCore

final class SpeechSetupOnboardingTests: XCTestCase {
    func testMissingSetupOffersOnlyOnceAndNeverReopensDuringReadinessChanges() {
        var state = SpeechSetupOnboarding()
        XCTAssertFalse(state.claimPresentation())
        state.assess(installed: false)
        XCTAssertTrue(state.needsSetup)
        XCTAssertTrue(state.claimPresentation())
        XCTAssertFalse(state.claimPresentation())
        state.assess(installed: true)
        state.assess(installed: false)
        XCTAssertFalse(state.claimPresentation())
        var nextLaunch = SpeechSetupOnboarding()
        nextLaunch.assess(installed: false)
        XCTAssertTrue(nextLaunch.claimPresentation())
    }
    func testInstalledSetupStaysQuietEvenIfAnotherModelIsSelectedLater() {
        var state = SpeechSetupOnboarding()
        state.assess(installed: true)
        state.assess(installed: false)
        XCTAssertFalse(state.needsSetup)
        XCTAssertFalse(state.claimPresentation())
    }
}
