# Status-item diagnostic: manual Xcode checks

This is a separate, dependency-free Xcode project. It does not import VoiceRelay,
load a profile, run a fixture, contact a service, or register a background worker.
It uses macOS 27.0 and separate diagnostic bundle identifiers. The system may
still perform its own app/Intents registration when you launch any diagnostic app.

Five schemes isolate the UI setup:

| Scheme | What it creates | Expected visible result |
| --- | --- | --- |
| `WindowRepro` | One ordinary SwiftUI window | A window titled **Window diagnostic** with a Quit button |
| `MenuBarExtraRepro` | One SwiftUI MenuBarExtra using the waveform symbol and window style | A waveform in the menu bar; clicking it opens a small panel with a Quit button |
| `MenuStyleRepro` | One SwiftUI MenuBarExtra using the waveform symbol and explicit `.menu` style | A waveform in the menu bar; clicking it opens a native pull-down menu with a Quit item |
| `StatusItemLifecycleRepro` | Ordinary AppKit control window; buttons separately create a native status item, add text/image, and attach a menu | A window titled **Status item lifecycle diagnostic**; no status item until explicitly requested |
| `StatusItemStartupRepro` | AppKit-only `LSUIElement` app creates a variable-width item and waveform at startup | A waveform only; its menu contains **Native startup diagnostic**, **Confirm menu action**, and **Quit diagnostic** |

None of the schemes uses the main application's package, configuration, state, resources,
preferences, custom Info.plist, or Xcode scheme. Xcode generates each diagnostic
app's Info.plist. No developer account is required for their local ad hoc signing.

## Current layout investigation

The existing stack localizes reentrant layout to status-item scene setup and a
frame-change notification that requests another window display. The precise
trigger is still unconfirmed. The [layout diagnosis guide](LAYOUT_DIAGNOSIS.md)
records the comparisons and steps for future update retests. Both interactive
native width modes completed the recorded stages without
a layout warning, while Intents/linkd messages persisted. The operator then
captured the warning in **StatusItemStartupRepro**, which creates the native item
at menu-bar-only startup. Its framework stack matches the earlier SwiftUI control
through frame 80. SwiftUI is not required to reproduce the warning, and replacing
MenuBarExtra is not a demonstrated remedy. The app-policy/timing/window differences
remain to be individually isolated. A subsequent fresh startup run confirms the
warning, menu opening, confirmation action, and normal Quit/cleanup path. It also
logs AppKit glass-window focus warnings during menu opening. Debug build and
signature checks passed. Continue development with the warnings tracked; no
additional unchanged comparison is required now. Thaw is installed but reported
stopped, so it is not an established cause. The [local feedback draft](APPLE_FEEDBACK_DRAFT.md)
records the reproduction; nothing was submitted.

Current saved-scheme note: **MenuBarExtraRepro** has a Run executable override
pointing to **StatusItemLifecycleRepro.app**. This operator setting was preserved.
Confirm the selected executable explicitly for each comparison; the new startup
scheme points to **StatusItemStartupRepro.app**.

## Previous experiment: window style versus menu style

October 2 result: the operator's console excerpts for **both** styles contain
Intents/linkd registration/connection messages, the layout-recursion warning,
and a task-name-port failure. The `.menu` style did not eliminate these messages.
The excerpts do not distinguish launch from clicking or explicitly report Quit
and responsiveness. See [the validation record](../../docs/VALIDATION.md) for
the evidence and its limits. Keep VoiceRelay's current window-style panel; retain
the steps below for future update comparisons rather than repeating them unchanged.

Subsequent retest: the operator reports a successful VoiceRelay build/run with
Xcode 27.2 beta after a Mac reboot. Its console still shows Intents/linkd and layout
recursion. That update/reboot did not eliminate those diagnostics. The standalone
style controls have not been separately reported on the new toolchain, and the
excerpt alone does not certify fresh GUI interactions.

Independent control: the operator also manually created a fresh default Hello
World macOS project in Xcode. Its excerpt reproduces Intents/linkd but does not
show layout recursion. This strengthens the shared environment/framework lead
for registration/connection errors and keeps layout as a separate investigation.
The beta OS remains a hypothesis; the exact failing component is not identified.

The operator now reports working launch checks and a visible VoiceRelay panel
showing local fixture completion, with console warnings still present. Continue
prototype development with these diagnostics tracked. The operator's beta macOS
is a possible contributor, not a confirmed cause. VoiceRelay retains its current
window-style panel after this warning comparison.

The saved `MenuBarExtraRepro` scheme was found launching `WindowRepro.app` during
preparation of this experiment. Its Run executable binding now points to
`MenuBarExtraRepro.app`; its unchecked **Debug executable** setting was preserved.
For comparable console evidence, set the debugger option consistently for both
menu-bar schemes as follows.

1. Quit VoiceRelay and any diagnostic app through their **Quit** controls. Finish
   any paused Xcode session using section 1 below.
2. Open this project in Xcode using **File → Open…**:

   `/path/to/VoiceRelay/Diagnostics/StatusItemRepro/StatusItemRepro.xcodeproj`

   If the new scheme does not appear in an already-open project, close and reopen
   the project. No project recreation or DerivedData deletion is required.
3. Select **MenuBarExtraRepro → My Mac** in the toolbar. Choose **Product → Scheme
   → Edit Scheme… → Run → Info**. Confirm **Executable: MenuBarExtraRepro.app**,
   **Launch: Automatically**, and check **Debug executable**. Close the dialog.
4. Disable the `_NSDetectedLayoutRecursion` symbolic breakpoint in the Breakpoint
   navigator (⌘8). Build (⌘B), then Run (⌘R). Show the console with ⇧⌘Y if needed.
   Record the two warning categories at launch, then click the waveform and record
   any additional warnings. Confirm the **Menu bar diagnostic** panel opens.
   Click **Quit diagnostic** before the next run.
5. Select **MenuStyleRepro → My Mac**. In the same scheme dialog confirm
   **Executable: MenuStyleRepro.app**, **Launch: Automatically**, and
   **Debug executable** checked. Build and Run. Click the waveform; expect a
   pull-down menu labeled **Menu style diagnostic**, rather than the larger panel.
   Record launch/click warnings separately, then choose **Quit diagnostic**.
6. Reply with the two rows below. Use **not observed** if the console was hidden,
   filtered, or the debugger was detached; that is not evidence of absent warnings.

| Scheme / style | Build passes? | Menu/panel opens? | Intents/linkd at launch or click? | Layout warning at launch or click? | Quit works? |
| --- | --- | --- | --- | --- | --- |
| MenuBarExtraRepro / `.window` | | | | | |
| MenuStyleRepro / `.menu` | | | | | |

The native menu uses ordinary menu items instead of a VStack with a fixed-width
panel. Style and content presentation therefore differ. If only the window-style
app warns, that narrows the lead but does not prove the modifier alone causes it.
Warnings in both strengthen the shared status-item/runtime lead. Interpret
Intents/linkd independently from layout; changing menu style may affect neither.

The new source includes the named `MenuStyleDiagnosticInertContent_Previews`
Canvas provider. Its Quit action does nothing. That preview shows content only,
not the native menu lifecycle; Canvas rendering remains an operator check.

## Remaining VoiceRelay interaction checks

After quitting the diagnostics, open `VoiceRelay.xcodeproj` and select
**VoiceRelay → My Mac**. Build and Run with the diagnostic breakpoint disabled.

1. Click the waveform, then **Settings…**. Confirm the settings window opens.
   To exercise configuration import with synthetic values, use **Select config.toml…**
   and select `/path/to/VoiceRelay/config.fixture.example.toml`.
   The label should change to that filename and show backend `mock`. If you had
   selected another profile, remember its path and reselect it after this check.
2. Return to the waveform panel and choose **Inspect**. After a completed fixture,
   confirm the inspection window shows its UUID, chunk count, semantic blocks,
   and narration. Record the UUID from the line below the article title.
3. Choose **Run / Resume Fixture** again in the same fixture folder. After completion,
   Inspect should show the same UUID and **0 newly synthesized**. This is the manual
   idempotence check, separate from the already-passing CLI check.
4. For pause/resume, note the current fixture folder in Settings, then use
   **Choose fixture folder…** to select a new dedicated empty test folder. Run the
   fixture and click **Pause** while it is processing. After it reports paused,
   choose **Run / Resume Fixture** and confirm completion. If it finishes too
   quickly to click Pause, report **not exercised**. Restore the original fixture
   folder afterward; leave fixture artifacts available for inspection.
5. Choose **Quit** from the panel. Confirm its waveform disappears. Run again in
   Xcode and confirm it appears, opens, and waits for an explicit fixture action.

Report each control result separately. No listening or live delivery acceptance
is implied by a successful mock-tone fixture.

## Retest after future updates

When the operator next installs an approved macOS or Xcode update, repeat the same
two style runs and the VoiceRelay open/Settings/Inspect/Quit checks. Record versions
with these read-only Terminal commands:

```sh
sw_vers
xcodebuild -version
```

Retain both warning categories, the launch/click trigger, debugger setting, and UI
result per scheme. Do not overwrite the earlier evidence or infer a fixed release
from an empty console. Updates, scheduled reminders, and system-service changes
are not performed by this project.

## Start here when no interface appears

`VoiceRelay` and `MenuBarExtraRepro` initially show only a waveform in the menu bar.
They have no Dock icon and do not automatically open an ordinary window. Click the
waveform to open their panel. VoiceRelay starts fixture processing only after its
explicit fixture action. `WindowRepro`, however, should have a Dock icon and open
an ordinary window. An absent waveform or an unresponsive panel remains a failure;
console warnings alone cannot establish whether either app works.

On October 2, the inspected Xcode diagnostic DerivedData contained
`Debug/MenuBarExtraRepro.app` and build/run records naming `MenuBarExtraRepro`;
it contained no `WindowRepro.app`. This is limited to that DerivedData directory,
not proof of which apps were launched elsewhere. Confirm the scheme name explicitly.

### A. Launch the prepared ordinary-window control in Finder

The two previously built diagnostic apps remain in the temporary directory below.
Their presence and strict signatures were rechecked on October 2. This comparison
does not launch an app from the agent or attach Xcode's debugger.

1. In Xcode, choose **Product → Stop** (⌘.) for any active diagnostic session.
2. Switch to **Finder**. Choose **Go → Go to Folder…** (⇧⌘G).
3. Paste this directory, press Return, then double-click **WindowRepro.app**:

   `/private/tmp/voicerelay-status-diagnostics/Build/Products/Debug`

4. Look for the **Window diagnostic** window and the **WindowRepro** Dock icon.
   If the Dock icon appears without a window, click it to bring the app forward
   and record whether that reveals the window. Record any Finder launch alert exactly.
5. If the window opens, click **Quit diagnostic** before the Xcode comparison.
   Otherwise, if the app is in the Dock, use its Dock context menu's **Quit**.
   If it cannot quit, record that separately; do not leave multiple copies running.

The directory is temporary. If it is missing, use the project-opening and build
steps below, then expand **Products** in Xcode's Project navigator (⌘1), right-click
**WindowRepro.app**, choose **Show in Finder**, and double-click that built app
after stopping the Xcode session.

### B. Run WindowRepro from Xcode without its debugger

1. Open the diagnostic project using section 2 below. Select **WindowRepro** and
   **My Mac** in the toolbar; the scheme name must not be `MenuBarExtraRepro`.
2. Choose **Product → Scheme → Edit Scheme…**.
3. Select **Run** on the left, then the **Info** tab. Confirm **Build Configuration**
   is **Debug**, **Executable** is **WindowRepro.app**, and **Launch** is
   **Automatically**. Record any mismatch before correcting it for this test.
4. Uncheck **Debug executable**, then click **Close**. This controls automatic
   debugger attachment; see [Apple's debugger guide](https://developer.apple.com/documentation/xcode/diagnosing-and-resolving-bugs-in-your-running-app).
5. Build (⌘B), then Run (⌘R). Check the window and Dock icon again. Record any
   Xcode launch error separately. Without the debugger, an empty Xcode console
   does not establish that warnings were absent.
6. Quit the diagnostic. If this works, recheck **Debug executable**, disable the
   diagnostic symbolic breakpoint in the Breakpoint navigator (⌘8), and run once
   more. Record whether Xcode says **Running** or **Paused** if no window appears.
   If paused, capture the stop reason and stack before continuing.
7. Leave **Debug executable** checked when finished so normal debugging is restored.

Report these three results first: **Finder launch**, **Xcode without debugger**,
and **Xcode with debugger**. If the first two work and only the third fails, the
debugger/pause configuration becomes the stronger lead. If Finder works but both
Xcode runs fail, compare scheme/launch settings. If Finder also fails, the problem
extends beyond Xcode's debugger; the launch alert, Dock behavior, and system/runtime
evidence become necessary. These outcomes narrow the investigation; they do not
by themselves establish a corrupt project or a confirmed macOS defect.

## 1. Finish the paused VoiceRelay session

If VoiceRelay is paused at `_NSDetectedLayoutRecursion`, open the Breakpoint
navigator (⌘8) and disable that symbolic breakpoint using its blue breakpoint
icon. In the debugger console enter `continue`, then press Return. After the app
continues, click its waveform menu-bar icon and choose **Quit**. If it cannot be
continued or quit normally, stop its debug session in Xcode and record that fact.
A debug-session Stop can produce a killed message; record spontaneous termination
separately.

## 2. Open the diagnostic project

1. In Xcode choose **File → Open…**.
2. In the file dialog press **⇧⌘G** (Go to Folder).
3. Paste this path and press Return:

   `/path/to/VoiceRelay/Diagnostics/StatusItemRepro/StatusItemRepro.xcodeproj`

4. Click **Open**. Keep the existing VoiceRelay project; nothing needs to be removed.

## 3. Run the ordinary-window control

1. At the top of Xcode, click the scheme selector near the triangular Run button.
2. Select **WindowRepro**, with **My Mac** as its destination.
3. Choose **Product → Build** (⌘B). Record any compile/build errors separately.
4. Choose **View → Debug Area → Show Debug Area** (⇧⌘Y) if the console is hidden.
   Make the console pane visible using the pane buttons in the debug area.
5. Choose **Product → Run** (⌘R). Leave diagnostic breakpoints disabled for this run.
6. Confirm the **Window diagnostic** window appears and responds.
7. Look in the console for each of these two categories:
   - Intents/registration/`com.apple.linkd.autoShortcut` connection messages.
   - The `layoutSubtreeIfNeeded` / layout-recursion warning.
8. Record the result in the table below. Click **Quit diagnostic** in the window.

## 4. Run the minimal menu-bar app

1. Change the scheme to **MenuBarExtraRepro**, destination **My Mac**.
2. Build (⌘B), then Run (⌘R), with diagnostic breakpoints still disabled.
3. This app has no Dock icon and initially has no ordinary window. Find the waveform
   icon in the Mac menu bar and click it.
4. Confirm the **Menu bar diagnostic** panel opens and responds.
5. Record both console-warning categories, including whether they appeared at launch
   or only after clicking the waveform.
6. Click **Quit diagnostic** in the panel.

## 5. Capture a stack only if the minimal app logs layout recursion

1. Open the Breakpoint navigator (⌘8).
2. Click **+ → Symbolic Breakpoint**.
3. Set **Symbol** to `_NSDetectedLayoutRecursion`; leave **Library** empty.
4. Run the same diagnostic scheme again from the beginning. The warning is logged
   once per process, so continuing the earlier run is not a reliable reproduction.
5. When paused, enter `thread backtrace` in the debugger console and press Return.
6. Copy that output and note which scheme/action caused the stop.
7. Disable the breakpoint again and enter `continue`. Quit the diagnostic normally.

## Send back these results

Fill in yes/no or a short description. Build success and visible UI behavior are
separate checks. Do not label warnings absent if the console was hidden or filtered.

| Run | Build succeeds? | Intents/linkd messages? | Layout recursion? | UI works? | Trigger/action |
| --- | --- | --- | --- | --- | --- |
| WindowRepro | | | | | |
| MenuBarExtraRepro | | | | | |
| MenuStyleRepro | | | | | |
| VoiceRelay, breakpoint disabled | | | | | |

Include the diagnostic backtrace if applicable. No profile, article text, endpoints,
or credentials are needed.

## How the comparison will be interpreted

- Layout recursion in the minimal menu-bar app substantially weakens the hypothesis
  that VoiceRelay's package integration or custom project wiring causes it. If the
  ordinary window is clean, the status-item lifecycle becomes the stronger lead.
- Intents/linkd messages in either minimal app show that those messages can occur
  without VoiceRelay's pipeline or any application AppIntents registration code.
- Clean diagnostic apps with warnings only in VoiceRelay justify a focused comparison
  of its scenes, label/content, bundle settings, and launch configuration. They do
  not by themselves prove a corrupt Xcode project.
- Any visible failure, hang, or spontaneous termination needs its own investigation.
  A console warning alone and a breakpoint-induced pause are different observations.

The next step is evidence-based isolation. Recreating the main project is not the
first action, and no production UI workaround has been applied.
