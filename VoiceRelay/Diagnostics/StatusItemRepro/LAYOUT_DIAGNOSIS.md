# Layout-recursion investigation

## Current conclusion: native startup also reproduces

The operator's latest breakpoint stack names `StatusItemStartupRepro`, the
AppKit-only menu-bar startup control. Frames 0–80 match the earlier SwiftUI
control exactly after addresses are removed. The same status-item scene
connection and view-frame notification reenter AppKit layout. SwiftUI and
VoiceRelay's panel/pipeline are not required to reproduce this warning.

The immediate mechanism is localized to AppKit's internal status-item startup
path. The exact internal receiver and underlying cause remain unknown. The clean
interactive native controls differ in timing, app policy, and ordinary-window
presence; they do not identify which factor matters. A framework/runtime defect
or environment interaction is the stronger lead, but beta-specific causation is
not proven. No demonstrated fix justifies recreating the project or changing the
production UI.

The operator subsequently stopped that process, cleared the console, and ran
again. The fresh log confirms macOS 27.2 `26B5091g`, `LSUIElement = true`, startup
stage completion, and the layout warning before the first logged menu opening.
It then confirms menu opening/closing, **Confirm menu action**, Quit, and cleanup.
These are fresh-run functional results, not continuation of the earlier paused
process. Native diagnostic interaction acceptance is now supported; VoiceRelay's
own remaining interaction and live/speech gates are separate.

Intents/linkd errors persist. Menu opening also logs an attempt to make an AppKit
`_NSGlassEffectWindow` key even though it is ineligible. The probe creates no
NSWindow and calls no key-window methods; internal menu presentation is the
stronger lead, with the caller unlocalized. Apple's
[canBecomeKey documentation](https://developer.apple.com/documentation/appkit/nswindow/canbecomekey)
explains that such focus attempts are abandoned when eligibility is false. The
action and Quit still run. A task-name-port failure also appears; the source
contains no process-port request and its originating caller is unknown.

Keep these messages tracked and retain the existing production UI. No further
unchanged diagnostic run is required now; retest after approved updates or new
functional symptoms. Disable the symbolic breakpoint during ordinary development
so its intentional pause is not mistaken for an unresponsive app. A local
[Apple feedback draft](APPLE_FEEDBACK_DRAFT.md) contains the reproduction and
evidence limits; nothing was submitted.

## What the existing evidence establishes

The supplied backtrace catches a second layout request while AppKit is already
laying out a status-item view. Reading from the older frames toward frame 0:

1. Status-item scene connection sets the item's display identifier (frames 43–48).
2. A window frame update causes display and layout (frames 21–42).
3. Layout changes a view's frame and posts a frame-change notification (17–20).
4. AppKit notification observers update a window's frame and request display (10–16).
5. Display requests layout again, reaching `_NSDetectedLayoutRecursion` (0–9).

There is no VoiceRelay callback in this chain beyond application startup. That
localizes the immediate mechanism, but does not identify the exact view/window
receiver or prove an operating-system defect. The reported debugger stop was
instruction stepping, not evidence of a crash.

Both minimal SwiftUI menu styles reproduce the warning in the operator's logs,
so VoiceRelay's richer panel content and window-style presentation are not
required to reproduce it. Both controls still share SwiftUI `MenuBarExtra`, a
waveform label, and the status-item lifecycle. The next comparison removes
SwiftUI and introduces the native item in stages.

The independent Hello World excerpt reproduces Intents/linkd errors but does not
show this layout warning. Treat those errors separately. Thaw is installed but
the operator reports it is currently stopped; there is no evidence establishing
it as the cause. No utility settings or system services were changed.

The subsequent symbolic-breakpoint capture successfully stops in the warning
function, but its frame 86 names `MenuBarExtraRepro.debug.dylib` and
`MenuBarExtraReproApp.swift`, with SwiftUI startup below. It repeats the same
status-item/frame-notification mechanism through an inner window-placement
layout path. It contains no probe markers, so the AppKit-only comparison remains
pending at that point. The saved new scheme's Run binding was rechecked and is correct.

## Operator result: square-width native item

The subsequent AppKit probe log records baseline, square-width creation, text,
waveform, menu attachment, Quit, and cleanup without a layout warning. The
operator reports no breakpoint hit. The native runtime class is
`NSSceneStatusItem`, so that class alone does not require the warning. Intents/
linkd errors persist independently of an observed layout warning in this run.

The attempted creation-mode change was ignored, as designed; variable width has
subsequently been exercised in a fresh run. The supplied square-width log lacks
menu opening/closing markers, so menu attachment and actual presentation must
be distinguished.

The comparison strengthens a SwiftUI scene/label-sizing or lifecycle lead but
also differs in startup timing, activation policy, and ordinary-window presence.
It does not establish an exact root cause or justify replacing the production UI
yet. A `(lldb)` prompt is expected when the debugger stops; if no warning or
breakpoint occurs, return the console and observed behavior without a backtrace.

## Operator result: variable-width native item

The next supplied log records variable-width creation followed by text, waveform,
menu attachment, Quit, and cleanup, again without a layout warning. Both width
modes now provide negative controls for those stages on macOS 27.2 `26B5091g`.
Intents/linkd messages still appear. Neither excerpt has menu opening/closing
markers. Item width alone and native waveform assignment are weaker explanations.
SwiftUI setup, startup timing, app policy, and ordinary-window presence remain
differences; this is not proof of a specific framework defect.

## Reproduction steps: native item at menu-bar-only startup

`StatusItemStartupRepro` imports AppKit only, sets `LSUIElement` in its generated
plist, and creates a variable-width waveform item during launch without opening
an ordinary window. It reads no configuration/data. It narrows the creation-time
and app-policy differences from the previous native controls, although the exact
framework callback timing and native content still differ from SwiftUI.

1. Quit active diagnostics and VoiceRelay. Open this same diagnostic Xcode project.
   Close and reopen the project if the new scheme is missing.
2. Select **StatusItemStartupRepro → My Mac**. In **Product → Scheme → Edit
   Scheme… → Run → Info**, confirm **StatusItemStartupRepro.app**, automatic
   launch, and **Debug executable** checked. Keep the symbolic breakpoint enabled.
3. Run (⌘R). Expect **no ordinary window or Dock icon**. The console should contain
   `[StartupProbe] BEGIN`, `LSUIElement = true`, and the creation/label/menu stages.
   Wait five seconds before clicking the new waveform.
4. At the first breakpoint stop, capture `thread backtrace -c 100` plus the
   preceding `[StartupProbe]` markers. Note whether it occurred at launch or click.
   Disable the breakpoint, continue, and quit normally if responsive.
5. If no stop or warning, click the waveform. Confirm the menu heading is **Native
   startup diagnostic**, then choose **Confirm menu action**. Expect
   `[StartupProbe] ACTION selected: menu content is interactive` in the console.
6. Reopen the menu and choose **Quit diagnostic**. Send the full console and
   observed menu/action/Quit results. No backtrace is required for a clean run.

The current **MenuBarExtraRepro** scheme has an operator-edited Run override to
the lifecycle diagnostic. It was preserved; choose the new startup scheme and
confirm the executable rather than using that older scheme's toolbar name as
evidence of which process is running.

The operator has now reproduced the warning with this native startup control;
see the current conclusion above. Retain these steps for future approved update
comparisons. Keep production UI unchanged until a proposed change has its own
interaction acceptance.

## Run the new AppKit-only probe

This diagnostic imports AppKit only. It starts with an ordinary control window
and creates no status item until you press a button. It does not read VoiceRelay
configuration or data. Each action writes a `[LayoutProbe]` console marker.

1. Quit VoiceRelay and any previous diagnostic through their Quit controls. In
   Xcode, stop any remaining debug session with **Product → Stop** (⌘.).
2. Choose **File → Open…** and open:

   `/path/to/VoiceRelay/Diagnostics/StatusItemRepro/StatusItemRepro.xcodeproj`

   Close and reopen this project if the new scheme is missing from an already-open
   Xcode window. Select **StatusItemLifecycleRepro → My Mac** in the toolbar.
3. Choose **Product → Scheme → Edit Scheme… → Run → Info**. Confirm executable
   **StatusItemLifecycleRepro.app**, launch **Automatically**, and **Debug
   executable** checked. Close the dialog.
4. Open the Breakpoint navigator (⌘8). Use its **+ → Symbolic Breakpoint…** and
   enter `_NSDetectedLayoutRecursion` as the symbol. Leave Library blank and
   automatic continuation off. If this breakpoint already exists, enable it
   instead of adding a duplicate. Ensure breakpoints are globally enabled.
5. Run (⌘R). Show the debug area with **View → Debug Area → Show Debug Area**.
   Keep the console unfiltered. A window titled **Status item lifecycle
   diagnostic** should open. Wait about five seconds before pressing a button.
   A breakpoint hit during this baseline is already useful; follow step 8.
   Confirm the console includes `[LayoutProbe] BASELINE`; a waveform-only app
   without that control window is one of the earlier SwiftUI diagnostics.
6. Press **1a. Create square-width item**, then wait about five seconds. An item
   without a label may look blank. If there is no warning or breakpoint hit,
   press **2. Set text label**, wait, then **3. Replace text with waveform**, wait,
   then **4. Attach native menu**, and wait again.
7. If still clean, click the new waveform in the menu bar. Expect a menu labeled
   **AppKit lifecycle diagnostic**. Close it and use **Quit diagnostic**. Record
   whether the window, menu, and Quit worked.
8. At the **first breakpoint hit**, stop the experiment and enter this in the
   debugger console next to `(lldb)`:

   ```text
   thread backtrace -c 100
   ```

   Copy the stack and preceding console output, including `[LayoutProbe]`
   markers. Record the last button pressed, or “baseline, no buttons pressed.”
   Do not step through the assembly. Disable the symbolic breakpoint, enter
   `continue`, and quit the diagnostic normally. If it will not respond, stop it
   in Xcode and report that separately.
9. If the entire square-width run is clean, Run again as a **fresh process** and
   choose **1b. Create variable-width item** instead. Repeat steps 6–8. If the
   first run warns, send that first result before testing additional variations.

The warning says it logs only once per process. Do not test both creation modes
in one launch. The markers delimit source actions, but asynchronous framework
work can occur after a “returned” marker. The fresh backtrace matters more than
the nearest log line. If the warning appears without a breakpoint stop, provide
the unfiltered console and last action; do not classify the run as clean.

## How to interpret the result

| First trigger | What it would tell us |
| --- | --- |
| Baseline, before item creation | Inspect the new stack: the ordinary control-window path or another startup path can reproduce it. |
| Bare item creation | Native AppKit status-item creation is sufficient in that run; SwiftUI and panel content are not required. |
| Text or variable-width mode only | Item sizing and content geometry become the next focused lead. |
| Waveform step | Symbol loading or the text/image change becomes the next lead; use substep markers and stack. |
| Menu attachment or opening | Focus on that menu lifecycle transition. |
| Both native modes stay clean | SwiftUI scene setup or other differences remain leads. The probe also differs in activation policy, ordinary-window presence, and deferred creation, so this alone does not prove a SwiftUI bug. |

Please return the creation mode, first triggering action (or “none observed”),
console/stack, and observed window/menu/Quit behavior. No private profile or data
is needed. We have not yet demonstrated a root-cause fix; changing the production
UI or recreating its Xcode project is not supported by this evidence.

## Agent validation, October 2, 2026

- Xcode 27.2 beta build `27B5028f`, macOS SDK 27.2; host macOS 27.2 build `26B5091g`.
- New scheme's arm64 Debug build passed; minimum deployment version remains 27.0.
- Strict code-signature verification passed. Generated plist names the correct
  executable and has neither `LSUIElement` nor `LSBackgroundOnly` enabled.
- New binary has no direct SwiftUI or VoiceRelayCore framework dependency.
- All four schemes' target/executable bindings passed static checks. Existing
  project objects were preserved except required group/target membership additions.
- All 34 captured production source/test/packaging/notices/main-project file hashes
  remained unchanged. No core behavior change or core test rerun.
- Agent GUI execution was not performed. The operator subsequently supplied the
  square- and variable-width results above; menu-opening markers were absent.
  The subsequent startup probe also passed arm64 Debug build, strict signature,
  minimum-27.0/LSUIElement plist checks, direct-framework dependency checks, and
  target/scheme checks. The operator subsequently captured its layout-recursion
  breakpoint, then supplied a fresh run confirming menu/action/Quit and cleanup
  despite the warning. Release remains unrun. Canvas does not exercise these
  native lifecycles. No automated GUI or live-data operation was performed.

Build log: `/private/tmp/voicerelay-layout-lifecycle-build.log`. The successful
build also emitted sandbox service/cache diagnostics and an App Intents metadata
extraction warning because the target has no AppIntents dependency. Those build
messages do not establish the runtime outcome.

Startup build log: `/private/tmp/voicerelay-layout-startup-build.log`. The same
build-tool service and skipped App Intents metadata extraction diagnostics were
present. The production source/test/packaging/notices/main-project baseline for
this addition contains 31 files; all remained unchanged. Existing diagnostic
source and scheme files were preserved, including the Run override noted above.
