import SwiftUI
import Testing
@testable import AppPresentation

@Test func appTextSizingIsBoundedAndScalesSemanticAndAccessibilitySizes() {
    #expect(AppTextSize.options.map(\.percent) == Array(stride(from: 80, through: 200, by: 10)))
    #expect(AppTextSize(percent: Int.min).percent == 80 && AppTextSize(percent: Int.max).percent == 200)
    #expect(AppTextSize().adjusted(by: 10).percent == 110)
    #expect(AppTextSize(percent: 80).adjusted(by: -10).percent == 80)
    #expect(AppTextSize(percent: 200).adjusted(by: 10).percent == 200)
    let sizes = DynamicTypeSize.allCases.map { AppTypography.pointSize(base: 16, size: AppTextSize(), dynamic: $0) }
    #expect(sizes == sizes.sorted() && sizes.first! >= 12 && sizes.last! > sizes.first!)
    #expect(AppTypography.pointSize(base: 12, size: AppTextSize(percent: 80), dynamic: .xSmall) == 12)
    #expect(AppTypography.pointSize(base: 16, size: AppTextSize(percent: 200), dynamic: .large) == 32)
}
