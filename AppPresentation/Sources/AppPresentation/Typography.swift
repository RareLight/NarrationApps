import SwiftUI
import AppKit

public struct AppTextSize: Equatable, Hashable, Sendable, Identifiable {
    public static let options = stride(from: 80, through: 200, by: 10).map { AppTextSize(percent: $0) }
    public let percent: Int
    public init(percent: Int = 100) { self.percent = min(200, max(80, percent / 10 * 10)) }
    public var id: Int { percent }
    public var label: String { "\(percent)%" }
    public var canIncrease: Bool { percent < 200 }
    public var canDecrease: Bool { percent > 80 }
    public func adjusted(by delta: Int) -> Self { Self(percent: percent + delta) }
}

private struct AppTextSizeKey: EnvironmentKey { static let defaultValue = AppTextSize() }
public extension EnvironmentValues {
    var appTextSize: AppTextSize {
        get { self[AppTextSizeKey.self] }
        set { self[AppTextSizeKey.self] = newValue }
    }
}

public enum AppTypography {
    public enum Style { case body, secondary, headline, title2, symbol, caption, caption2, callout, subheadline, title, largeTitle, footnote }
    public static let minimumPointSize: CGFloat = 12
    // macOS does not scale fonts from DynamicTypeSize itself. Resolve both the
    // requested category and the app preference explicitly, retaining native fonts.
    public static func scale(size: AppTextSize, dynamic: DynamicTypeSize) -> CGFloat {
        let category: CGFloat
        switch dynamic {
        case .xSmall: category = 0.8
        case .small: category = 0.9
        case .medium: category = 0.95
        case .large: category = 1
        case .xLarge: category = 1.15
        case .xxLarge: category = 1.3
        case .xxxLarge: category = 1.45
        case .accessibility1: category = 1.7
        case .accessibility2: category = 2
        case .accessibility3: category = 2.35
        case .accessibility4: category = 2.75
        case .accessibility5: category = 3.1
        @unknown default: category = 1
        }
        return CGFloat(size.percent) / 100 * category
    }
    public static func pointSize(base: CGFloat, size: AppTextSize, dynamic: DynamicTypeSize) -> CGFloat {
        max(minimumPointSize, base * scale(size: size, dynamic: dynamic))
    }
}

private struct AppTextFont: ViewModifier {
    let style: AppTypography.Style
    @Environment(\.appTextSize) private var size
    @Environment(\.dynamicTypeSize) private var dynamic
    func body(content: Content) -> some View {
        let preferred: NSFont = switch style {
        case .body: .preferredFont(forTextStyle: .body)
        case .headline: .preferredFont(forTextStyle: .headline)
        case .title2: .preferredFont(forTextStyle: .title2)
        case .secondary: .systemFont(ofSize: 12)
        case .symbol: .systemFont(ofSize: 16)
        case .caption: .preferredFont(forTextStyle: .caption1)
        case .caption2: .preferredFont(forTextStyle: .caption2)
        case .callout: .preferredFont(forTextStyle: .callout)
        case .subheadline: .preferredFont(forTextStyle: .subheadline)
        case .title: .preferredFont(forTextStyle: .title1)
        case .largeTitle: .preferredFont(forTextStyle: .largeTitle)
        case .footnote: .preferredFont(forTextStyle: .footnote)
        }
        let points = AppTypography.pointSize(base: preferred.pointSize, size: size, dynamic: dynamic)
        let font = NSFont(descriptor: preferred.fontDescriptor, size: points) ?? .systemFont(ofSize: points)
        content.font(Font(font))
    }
}
public extension View {
    func appFont(_ style: AppTypography.Style) -> some View { modifier(AppTextFont(style: style)) }
    func appTextSizing(_ size: AppTextSize) -> some View { appFont(.body).environment(\.appTextSize, size) }
}


public struct AppTextSizeCommands: Commands {
    @Binding private var size: AppTextSize
    public init(size: Binding<AppTextSize>) { _size = size }
    public var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Larger Text") { size = size.adjusted(by: 10) }
                .keyboardShortcut("+", modifiers: .command).disabled(!size.canIncrease)
            Button("Smaller Text") { size = size.adjusted(by: -10) }
                .keyboardShortcut("-", modifiers: .command).disabled(!size.canDecrease)
            Button("Reset Text Size") { size = AppTextSize() }
                .keyboardShortcut("0", modifiers: .command).disabled(size == AppTextSize())
        }
    }
}
