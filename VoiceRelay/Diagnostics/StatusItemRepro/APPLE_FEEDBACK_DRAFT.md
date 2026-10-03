# AppKit status-item scene connection reenters layout in a native LSUIElement app

Local draft, October 2, 2026. Not submitted. The operator can review this text
before using Feedback Assistant. It records a reproduced warning, not a confirmed
Apple defect or a crash.

## Environment

- Last verified toolchain: Xcode 27.2 beta, build `27B5028f`, macOS SDK 27.2.
- Host reported in the fresh native startup log: macOS 27.2, build `26B5091g`.
- Apple Silicon; diagnostic Debug build targets arm64 and minimum macOS 27.0.
- Local ad hoc signing, no App Sandbox or hardened runtime.
- Generated Info.plist: `LSUIElement = YES`; isolated bundle identifier
  `org.voicerelay.diagnostics.startup`.
- Thaw installed but reported not running. Its settings/process state were not
  independently inspected or changed.

The backtrace itself does not include environment versions; the subsequent
console confirms the host version. Confirm versions again when submitting if
the system/toolchain has changed.

## Minimal reproduction

The separate `Diagnostics/StatusItemRepro/StatusItemRepro.xcodeproj` contains the
`StatusItemStartupRepro` scheme. The entire application source is
[`StatusItemStartupReproApp.swift`](StatusItemStartupReproApp.swift).

This app imports only AppKit and has no external packages, SwiftUI hosting view,
custom layout override, ordinary window, network request, or data dependency.
Its delegate retains a variable-width `NSStatusItem`, assigns the waveform
system-symbol image, and attaches an ordinary `NSMenu` during
`applicationDidFinishLaunching`. It then runs AppKit's normal event loop.

1. Select `StatusItemStartupRepro → My Mac` in the diagnostic Xcode project.
2. Confirm Run executable `StatusItemStartupRepro.app`, automatic launch, and
   **Debug executable** enabled.
3. Add/enable a symbolic breakpoint on `_NSDetectedLayoutRecursion` with no
   automatic continuation. Run and retain the `[StartupProbe]` console markers.
4. At the breakpoint, capture `thread backtrace -c 100`.
5. Disable the breakpoint, continue, then select **Confirm menu action** and
   **Quit diagnostic** from the waveform menu to report interaction separately.

Expected: status-item initialization completes without reentering layout on a
view already being laid out.

Observed: the operator hit `_NSDetectedLayoutRecursion` on the main thread with
stop reason breakpoint 1.1 in the native diagnostic. The supplied attachment
contains the stack, but no console markers identifying the last source action.
The operator then stopped that process, cleared the console, and restarted.
The fresh run logs the same warning after startup setup returns and before the
first logged menu opening. It proceeds through menu/action/Quit and termination
cleanup. This establishes a second native startup reproduction, not a measured
failure frequency or continuation of the paused process.

Selected fresh-run markers, in order:

```text
[StartupProbe] Version 27.2 (Build 26B5091g)
[StartupProbe] LSUIElement = true; activation policy = 1
[StartupProbe] STEP 1 returned: runtime class NSSceneStatusItem
[StartupProbe] STEP 3 returned: click waveform, choose Confirm menu action, then Quit diagnostic
[layout-recursion warning]
[StartupProbe] MENU will open
[StartupProbe] MENU did close
[StartupProbe] ACTION selected: menu content is interactive
[StartupProbe] MENU will open
[StartupProbe] MENU did close
[StartupProbe] QUIT requested from native menu
[StartupProbe] TERMINATING: remove owned status item
```

The bracketed warning placeholder abbreviates the full operator log; it is not
a literal source marker. Exact elapsed times and click timing were not supplied.

## Captured framework mechanism

The backtrace shows, from older frames toward the warning:

- 40–45: `NSStatusItem _setDisplayIdentifier`, `NSSceneStatusItem` variant-scene
  setup/connection, and `NSStatusItemVariantSceneDelegate` connection.
- 14–39: display/layout changes a view frame and posts a frame-change notification.
- 5–13: AppKit notification observers reenter `NSWindow _setFrameCommon`,
  `_oldPlaceWindow`, and `_layoutViewTree`.
- 0–4: another `layoutSubtreeIfNeeded` reaches `_NSDetectedLayoutRecursion`.
- 80–85: `NSApplication.run` and `StatusItemStartupReproApp.main`; no SwiftUI frames.

Frames 0–80 match an earlier minimal SwiftUI `MenuBarExtra` control's stack exactly
after addresses are removed. Ordinary-window AppKit controls that create their
item interactively later completed square- and variable-width creation, text,
waveform, and menu attachment without a layout warning in the supplied logs.
Those controls differ in app policy, creation timing, and window presence, so
the comparison does not establish which difference causes the warning.

Independent Intents/linkd registration/connection messages also appear in the
clean native controls and an operator-created default Hello World app. Their
relationship to the layout warning is not established; investigate separately.

The fresh native startup log also includes a task-name-port failure and, on both
menu openings, a `makeKeyWindow` warning for AppKit `_NSGlassEffectWindow` with
`canBecomeKeyWindow = NO`. The reproduction source creates no NSWindow or
process-port request and calls no key-window methods. Originating stacks for
these messages are not available. Menu action and Quit still execute.

## Evidence to include after review

- This minimal source and target settings, or the dependency-free diagnostic project.
- The native startup backtrace already captured by the operator.
- The fresh `[StartupProbe]` console, marker ordering, and menu/action/Quit results.
- Current OS/Xcode versions and any subsequent reproduction attempts.

No private VoiceRelay configuration, article content, credentials, or podcast
artifacts are needed for this reproduction.
