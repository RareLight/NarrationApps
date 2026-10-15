import SwiftUI

/// Apps own pane identity and persistence; navigation owns only presentation.
public protocol SettingsPane: Hashable, Identifiable, CaseIterable where ID == Self {
    var title: String { get }
    var systemImage: String { get }
    var help: String { get }
}

public struct SettingsNavigation<Pane: SettingsPane>: View {
    @Binding private var selection: Pane
    @Environment(\.appTextSize) private var textSize
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var selectedTile
    @FocusState private var focusedPane: Pane?
    @State private var keyboardNavigation = false
    public init(selection: Binding<Pane>) { _selection = selection }
    public static var idealWidth: CGFloat { CGFloat(Pane.allCases.count) * 92 + CGFloat(max(0, Pane.allCases.count - 1)) * 8 }
    private var scale: CGFloat { max(1, AppTypography.scale(size: textSize, dynamic: dynamicType)) }
    public var body: some View {
        ViewThatFits(in: .horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(Array(Pane.allCases)) { pane in
                        Button {
                            if NSApp.currentEvent?.type == .keyDown { keyboardNavigation = true }
                            else { focusedPane = nil; keyboardNavigation = false }
                            if reduceMotion { selection = pane }
                            else { withAnimation(.smooth(duration: 0.2)) { selection = pane } }
                        } label: { paneLabel(pane) }
                            .buttonStyle(.plain).focused($focusedPane, equals: pane).focusEffectDisabled()
                            .accessibilityLabel(pane.title)
                            .accessibilityAddTraits(selection == pane ? .isSelected : [])
                            .help(pane.help)
                    }
                }
            }
            .frame(width: Self.idealWidth * scale, height: 46 * scale)
            Picker("Settings pane", selection: $selection) {
                ForEach(Array(Pane.allCases)) { Text($0.title).tag($0) }
            }.pickerStyle(.menu)
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Settings panes")
        .onChange(of: focusedPane) { _, focused in
            if focused != nil, NSApp.currentEvent?.type == .keyDown { keyboardNavigation = true }
        }
    }
    @ViewBuilder private func paneLabel(_ pane: Pane) -> some View {
        let label = VStack(spacing: 4) {
            Image(systemName: pane.systemImage).appFont(.symbol)
            Text(pane.title).appFont(.secondary).lineLimit(1)
        }
        .frame(width: 92 * scale, height: 46 * scale)
        .contentShape(Rectangle())
        .foregroundStyle(selection == pane ? Color.accentColor : Color.secondary)
        .overlay {
            if keyboardNavigation && focusedPane == pane {
                RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 1.5).padding(-2).allowsHitTesting(false)
            }
        }
        if selection == pane {
            if reduceTransparency { label.background(.background, in: .rect(cornerRadius: 8)) }
            else { label.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8)).glassEffectID("selected-settings-pane", in: selectedTile) }
        } else { label }
    }
}

public struct SettingsSectionHeader: View {
    private let title: String
    private let explanation: String?
    private let moreHelp: (() -> Void)?
    @State private var showingInfo = false
    public init(title: String, explanation: String? = nil, moreHelp: (() -> Void)? = nil) {
        self.title = title; self.explanation = explanation; self.moreHelp = moreHelp
    }
    public var body: some View {
        HStack(spacing: 6) {
            Text(title).appFont(.headline)
            if let explanation {
                Button { showingInfo = true } label: { Image(systemName: "info.circle").appFont(.secondary) }
                    .buttonStyle(.plain).help("About \(title)")
                    .accessibilityLabel("About \(title)").accessibilityHint("Show a brief explanation")
                    .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(explanation).textSelection(.enabled)
                            if let moreHelp {
                                Button("More Help…") { showingInfo = false; moreHelp() }
                            }
                        }.appFont(.secondary).frame(idealWidth: 280, maxWidth: 320, alignment: .leading).padding(10)
                    }
            }
        }
    }
}

public struct AppearanceSettingsSection: View {
    @Binding private var textSize: AppTextSize
    public init(textSize: Binding<AppTextSize>) { _textSize = textSize }
    public var body: some View {
        Section {
            Picker("Text size", selection: $textSize) {
                ForEach(AppTextSize.options) { Text($0.label).tag($0) }
            }
            Button("Reset Text Size") { textSize = AppTextSize() }.disabled(textSize == AppTextSize())
        } header: {
            SettingsSectionHeader(title: "Appearance", explanation: "Applies throughout this app. Use ⌘+ and ⌘− to adjust text, or ⌘0 to reset. Small text stays at least 12 points.")
        }
    }
}

public struct SettingsNotice: View {
    private let message: String
    private let onDismiss: (() -> Void)?
    @State private var hovering = false
    @FocusState private var dismissFocused: Bool
    public init(message: String, onDismiss: (() -> Void)? = nil) { self.message = message; self.onDismiss = onDismiss }
    public var body: some View {
        HStack(spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).focused($dismissFocused).opacity(hovering || dismissFocused ? 1 : 0)
                    .accessibilityHidden(false).accessibilityLabel("Dismiss error").help("Hide this message").frame(width: 18)
            }
        }.onHover { hovering = $0 }.appFont(.body)
    }
}
