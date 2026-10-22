# Shared macOS design and UX reference

Design baseline: October 9, 2026 · macOS 27 / Xcode 27.
Current implementation ownership and terminology reviewed October 21, 2026.

Use this document when designing or developing our Mac applications. The goal is
recognizable behavior, restrained native presentation and clear workflows across
products. Each app should still express its own purpose through its content,
terminology and appropriate navigation. For other platforms, carry over the
workflow principles while using that platform’s own controls; do not imitate Mac
window chrome inside a web page.

This reference distills the approved Libro **Compact controls** direction and
its implemented refinements. **Shared rules** below are our conventions. Apple
links explain the platform guidance behind them; they do not imply that Apple
prescribes our exact layout, spacing or batch semantics. **Libro examples** show
how to apply the rules and are not requirements for every product.

## 1. Design intent

A user should quickly understand what they can add or edit, what choices affect
the result, where the result will go, what action starts the work and how to
recover if it fails. Build the interface around that sequence.

Our common character is:

- **Native:** real Mac controls, windows, menus, dialogs and keyboard behavior.
- **Content-led:** documents, results or the editor occupy the principal space.
- **Compact:** useful information density with readable labels and room to work.
- **Calm:** restrained color and decoration; emphasis identifies actions/state.
- **Explicit:** settings, destinations, active operations and recovery are clear.
- **Trustworthy:** completion means usable results; errors preserve prior work.

Apple's macOS guidance supports resizable windows, menu commands and keyboard
workflows. Apply those expectations to each app's actual task.
[Apple: Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)

## 2. Window structure and control placement

For a focused processing utility, use this anatomy:

```text
Native title bar and toolbar         Add…     Secondary actions
─────────────────────────────────────────────────────────────
Compact task choices                 Readiness when relevant
─────────────────────────────────────────────────────────────
Main working area                   Documents / editor / results
                                    Selection and local actions
─────────────────────────────────────────────────────────────
Destination or result context       Reveal    Browse…
Activity, completion or recovery     Cancel / primary action
```

Keep task choices near the content they affect. Put a result destination close
to the action that writes there. Use one prominent primary action for the current
workflow, with an explicit verb such as **Generate Audio**, **Export** or
**Convert**. Primary actions belong in a stable, easy-to-find location; the
lower trailing corner is our default for batch utilities, not a rule for editors.

Use a native toolbar for frequent window-level actions such as adding content.
Group related actions and keep the number of groups small. A secondary actions
menu can hold genuinely less frequent queue operations. Do not hide the app's
essential first action behind an unlabeled More menu. Every toolbar command
should also be reachable from an appropriate menu-bar command.
[Apple: Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)

Choose navigation from the product's structure:

| Product/task | Preferred starting point | Add only when justified |
|---|---|---|
| One-purpose processing utility | Compact choices + queue + destination/action | Next-operation settings sheet |
| Single-document editor | Main editor + context-sensitive toolbar | Inspector for frequent selection properties |
| Library or project application | Native sidebar + content/detail area | Search/filter when the collection requires it |
| Occasional configuration | Native Settings window | Additional tabs when coherent categories emerge |

A sidebar needs meaningful navigation destinations. An inspector needs enough
frequently used selection-specific information to earn its width. Neither is
part of the shared style merely because another app uses one.
[Apple: Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)

## 3. Visual language

### Materials and Liquid Glass

Target the agreed macOS 27 SDK and use standard SwiftUI/AppKit components first.
Allow the system to supply toolbar, control and presentation materials. Keep
working content visually stable and readable beneath the control layer. Add
custom glass only where a functional control genuinely needs a custom surface;
review it for overlap, contrast and accessibility. Avoid decorative stacks of
glass, bespoke toolbar backgrounds or blanket blur across text-heavy content.
[Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)

Liquid Glass is a platform behavior, not a collection of fixed opacity, blur or
shadow values. Do not make agents reproduce a screenshot's material with custom
CSS-like effects in a native app. Review the compiled app on the target OS.

### Type, color, symbols and spacing

| Element | Shared convention |
|---|---|
| Typography | System fonts and semantic text styles; normal size for essential content, headline for local section titles, caption for supporting context |
| Values | Monospaced digits for changing counts, rates and progress where alignment helps |
| Colors | Semantic primary/secondary text, system surfaces and accent; adapt to system appearance and user accent choices |
| Status | Text plus a meaningful symbol; color reinforces meaning and never carries it alone |
| Icons | SF Symbols for native actions; use a visible label for ambiguous or important actions and an accessible name for icon-only controls |
| Separators | Native dividers between major regions; whitespace within related groups |
| Controls | Standard sizes, focus rings, corner treatment and interaction feedback |
| Content surfaces | Tables, lists, forms and editors; avoid putting each row/section into a decorative card |

For custom layout gaps, **8, 12 and 16 points** are a useful starting vocabulary
from Libro: smaller gaps within groups, larger gaps between regions, roughly
16-point content insets. Prefer system spacing where available. These are our
starting values, not Apple requirements or mandatory control dimensions. Native
forms, sheets and new SDK controls can need different spacing.

Use a consistent hierarchy rather than hardcoded tiny type to make a layout fit.
Allow labels to reflow and controls to wrap. Keep useful density without imitating
a web dashboard or phone-sized touch interface.
[Apple: Layout](https://developer.apple.com/design/human-interface-guidelines/layout)

### Resizing and long content

Design the minimum window size from the actual content. Preserve usable queue or
editor space when banners, progress or configuration appear. Wrap compact
controls into a second row before essential labels clip. Move occasional editing
into a sheet if expanding it would consume the working area.

Truncate long filenames or paths only when necessary. Preserve the distinguishing
part of the name, supply full-path help and an accessible way to inspect/copy it.
A tooltip supplements information; it cannot be the only way to discover an
essential action or error. Provide scrolling where the data genuinely needs it,
not as the default workaround for unnecessary columns.

**Libro example:** three columns—Document, Output, Status—replaced six. The native
content minimum is 780 × 580 points and the default is 1000 × 680. Other apps
should choose their own sizes rather than inherit those numbers.

## 4. Main window, Settings and disclosure

Classify controls by their relationship to the current task, not merely whether
their values persist. A remembered output format is still a task choice.

| Question the control answers | Place it here | Libro example |
|---|---|---|
| What will this operation produce? | Main task controls | Model, voice, speed, format |
| Where will this result go? | Visible result/destination region | Save audio to + Browse + Reveal |
| What content am I acting on? | Main working area/selection controls | Documents, output names, preview |
| What changes the whole app or prepares its environment? | Settings | Workspace, explicit model preparation |
| What is useful mainly for diagnosis? | Troubleshooting | Debug logging and embedded-helper check |
| What technical detail supports an informed choice? | Nearby help or disclosure | Format fidelity; pinned model revision |
| What changes only later work during processing? | Explicit next-operation editor | Next Batch Settings… sheet |

Use a native Settings scene/window, grouped forms and concise categories. Offer
sensible defaults and show only settings with a useful purpose. Respect system
appearance and accessibility preferences; do not add redundant theme, contrast
or glass controls by default. Settings must function independently of whether
the main window is open.
[Apple: Settings](https://developer.apple.com/design/human-interface-guidelines/settings)

Use disclosure to reduce noise, not conceal blockers. Readiness, an unavailable
destination, failure cause and the recovery action stay visible. Exact revisions,
worker counts, attempts, import statistics and diagnostic identifiers can be
secondary. Supply a visible route into Settings when setup blocks the task.

**Libro example:** Models and Advanced are its two Settings categories. Other
apps may use different category names; they should preserve the same distinction
between task choices, general configuration and diagnosis.

## 5. Shared task and state flow

Our baseline for asynchronous file-processing work is:

**Add → inspect/edit → validate → start → process → publish → review results.**

| State | What the interface communicates | Available/relevant action |
|---|---|---|
| Empty | What input is supported and how to add it | Labeled Add… action; drop guidance |
| Needs setup | The missing prerequisite and a route to fix it | Browse, Prepare… or Settings… |
| Ready | Content, task choices, destination and any replacement notice | Primary action |
| Preparing | What is being prepared and actual measured progress | Cancel preparation |
| Processing | Current item/phase and meaningful completed work | Cancel; permitted next-operation edits |
| Publishing | Results are being finalized; processing is not yet saved | Wait or safe cancellation if supported |
| Cancelling | Cancellation is in progress; resources are stopping | Wait; do not imply it stopped instantly |
| Complete | Saved/succeeded and failed counts; usable result actions | Open/play/reveal; queue later work |
| Failed | Concise cause, affected item and recovery | Details, edit, Browse or Queue Again |

Use one main activity/completion region, with per-item status where needed. A
progress bar represents measured work, not decorative motion or a guessed time
estimate. Use determinate progress for known totals and indeterminate feedback
for phases whose extent is unknown. Name the phase so a user understands why the
indicator changes; do not equate synthesis/processing completion with publication.
[Apple: Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)

### Current work and later edits

Capture the operation's settings and destination when it starts. Keep that
snapshot visible and immutable while processing. If later edits are permitted,
label their scope explicitly: **Next Batch Settings…**, not an ambiguous enabled
picker that appears to change work already underway. Added content waits for the
next operation unless the product explicitly supports modifying an active one.

**Queue Again** means scheduling later work. **Retry Now** means immediately
starting another attempt. Pick the term that matches the behavior. In Libro,
Queue Again enables an explicit later Generate action; it does not start speech.

### Failures and disabled actions

Give a disabled primary action a nearby reason and a useful recovery step. For
example: “Choose an output folder with Browse,” or “Resolve the output-name
conflict before starting.” Use the same availability rule for the button, menu
command and recovery message so the interface cannot contradict itself.

Show a concise user-facing failure first. Offer technical details on demand,
including local logs where appropriate. Preserve previously complete outputs
when another attempt fails or is cancelled. Ask about intentional replacement
before starting a batch, not once per output. Do not silently change a chosen
location, format or processing mode to get past a failure.

These operation and storage rules are our product conventions, not prescribed
Apple UI mechanics. Adapt them to applications with autosave or continuous work
while preserving the same clarity and protection of user work.

## 6. Files, persistence, lifecycle and privacy

Use native Open/Save/folder dialogs for filesystem choices. Support Finder
opening and drag-and-drop where files are a central input, including a populated
window. Explain accepted types and whether folders are recursive. For batch
utilities, deduplicate overlapping input selections and explain ignored/invalid
inputs without flooding the main window.

Remember meaningful choices across launches: output format, explicitly chosen
destination and configuration that the user reasonably expects to persist. Use
appropriate bookmarks to restore directory access. An unavailable remembered
folder keeps its name/path visible and requires recovery; never silently write
somewhere else. Expose Browse and Reveal beside the destination.

Specify window-close and app-quit behavior for every long-running task. For our
batch utilities, closing the main window keeps work running; reopening restores
the active task. Quitting during work offers a clear choice to keep processing
or cancel and quit. Tell users whether completion survives closure and whether a
queue is session-only. Other app types can have different lifecycle behavior,
but it must be explicit and tested.

Completion notifications are optional assistance, not the only record of results.
For batch work, send at most one concise completion summary after final outputs
are published. Keep filenames, document text, full paths and other private content
out of notifications by default. Handle denied permission in the app and expose
notification status in Settings without permanently occupying the main window.
[Apple: Notifications](https://developer.apple.com/design/human-interface-guidelines/notifications/)

Debug logging belongs in Advanced Settings, defaults to off and explains its
privacy/storage implications. Keep it local, bounded and easy to open/reveal.
Do not imply that diagnostic logs cannot contain private upstream messages.

## 7. Keyboard, accessibility and language

Support the whole primary workflow through the keyboard. Keep native focus
indication and a logical Tab/Shift-Tab sequence. Never repurpose system or
accessibility shortcuts. Scope queue/navigation handlers to their focused view,
so they cannot intercept ordinary text-field editing.

| Action | Shared expectation |
|---|---|
| Settings | Command-comma |
| Open/add documents | Command-O where opening is the app's relevant action |
| Close window / quit app | Command-W / Command-Q with appropriate task lifecycle |
| Table/list navigation | Arrows and native multi-selection conventions |
| Remove queue item | Delete while the queue has focus; not deletion of the source file |
| Text editing | Native selection, deletion, clipboard and Undo behavior |
| Sheet default action | Return when safe; do not trigger generation from an output-name edit |
| Dismiss presentation | Escape for dismissible previews/settings sheets; preserve normal text behavior |
| Cancel work | A visible Cancel action; Command-period where appropriate |
| App-specific commands | Discoverable menu labels and shortcuts; avoid reserved combinations |

Libro additionally uses Command-Y/Space for selected-text preview and
Command-Shift-G for Start Queue. Those are product choices, not universal requirements
for unrelated apps or overrides of more appropriate existing conventions.
[Apple: macOS accessibility programming guidance](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/OSXAXDeveloping.html)

Prefer native accessible controls and labels. Add custom accessibility metadata
only where it improves the spoken interface; verify how combined rows, editable
cells and icon-only actions are actually exposed. Useful names, values, enabled
states and recovery actions matter more than the number of modifiers added.
Announce meaningful phase changes and failures without narrating every chunk or
refresh. Accessibility-tree inspection and a successful build do not establish
VoiceOver usability.

Test light/dark appearance, Increase Contrast, Reduce Transparency, Reduce Motion,
Differentiate Without Color and keyboard-only operation. Pair status symbols
with words, retain focus visibility and validate custom material behavior under
these preferences. Readability takes priority over preserving a particular glass
effect. Do not change a user's OS preferences silently while testing.
[Apple: Testing system accessibility features](https://developer.apple.com/documentation/accessibility/testing-system-accessibility-features-in-your-app)

Use familiar nouns and action verbs. Match wording across toolbar, menu, context
menu and sheet. Use system-appropriate capitalization rather than hand-styled
all-caps labels. Friendly names may be shown instead of technical IDs, but keep
IDs available in help/details where useful. Avoid “Error occurred” when the cause
is known. Prefer “This document contains no narration text after cleanup.”

## 8. Current native implementation

Libro now uses Start/Pause/Resume, Skip and Stop controls beside cover editing,
with Save Location and concise status along the bottom. Native table dragging
reorders eligible waiting rows. Settings has General, Document, Models,
Pronunciation and Troubleshooting; Document examples start collapsed. These are
current product examples, not a mandate to give VoiceRelay a batch interface.

Use the shared [AppPresentation conventions](../../docs/SETTINGS_ALIGNMENT.md)
and [operator checklist](../../docs/OPERATOR_VALIDATION.md#libro)
for the implemented controls and manual appearance/VoiceOver checks. The retired
HTML mockups and exported style-reference archive remain in the original
repository and Git history; they are not native runtime specifications.

## 9. Agent handoff and acceptance checklist

Give an implementing agent this document plus the target application's existing
instructions and task requirements. Preserve working behavior, persistence keys,
output contracts and unrelated changes. Apply the design in small complete steps.
Prefer existing components; do not introduce a shared theme framework, new UI
library or custom download/processing system merely to follow this reference.

A useful handoff prompt:

> Use the shared macOS style reference as the design baseline. Inspect this app's
> existing code and instructions first. Keep task choices near their content and
> destinations near output actions; move infrequent configuration and diagnostics
> into native Settings. Prefer native macOS 27 controls and system materials.
> Preserve current behavior and user work. Adapt navigation to this product's
> actual information structure rather than copying Libro's queue. Implement and
> validate incrementally, and separate fixture/build checks from actual GUI and
> human accessibility/appearance acceptance. Cite justified deviations.

Use the following as reusable design-review prompts, not a second list of pending
operator signoffs; report product acceptance through the shared operator IDs.
Before declaring a UI complete:

- [ ] Identify the first action, main content, task choices, destination and primary
  action without needing an explanatory tour.
- [ ] Exercise empty, ready, missing setup, invalid input/conflict, running,
  publishing, cancelling, mixed success/failure and complete states.
- [ ] Check minimum/default/resized windows, long names/paths, expanded details
  and active-task presentations without losing the working area.
- [ ] Verify consistent toolbar/menu/context actions and all keyboard paths,
  including editing fields while shortcuts are present.
- [ ] Relaunch to verify promised persistence and unavailable-folder recovery.
- [ ] Check cancel, replacement safety, close/reopen and quit during work.
- [ ] Inspect the accessibility tree and perform a separate VoiceOver pass.
- [ ] Check supported appearance/accessibility preferences on the target OS.
- [ ] Run targeted behavior tests and appropriate builds; record commands/results.
- [ ] Distinguish prototype inspection, fixtures, successful builds, real processing,
  human UI acceptance and subjective media evaluation in the report.

## 10. Source index

Official Apple references checked October 9, 2026. Use the current macOS sections;
Apple's cross-platform examples and archived material are not interchangeable
with a macOS 27 implementation. No third-party commentary is normative here.

| Reference | Used for |
|---|---|
| [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/) | Windows, menus, input and Mac work styles |
| [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) | System adoption, custom-material restraint, resizing and accessibility adaptations |
| [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) | Frequent commands, logical grouping and menu-bar equivalents |
| [Settings](https://developer.apple.com/design/human-interface-guidelines/settings) | Task-specific choices versus infrequent configuration; system preferences |
| [Layout](https://developer.apple.com/design/human-interface-guidelines/layout) | Grouping, hierarchy and progressive disclosure |
| [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) | Meaningful navigation, hierarchy and space tradeoffs |
| [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators) | Honest progress, phase context and cancellation |
| [Notifications](https://developer.apple.com/design/human-interface-guidelines/notifications/) | Concise, nonduplicated, privacy-conscious updates |
| [Testing system accessibility features](https://developer.apple.com/documentation/accessibility/testing-system-accessibility-features-in-your-app) | Appearance and assistive-feature validation |
| [Designing an accessible OS X app — archived](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/OSXAXDeveloping.html) | Durable keyboard-navigation principles; not current appearance/API guidance |
| [Build an AppKit app with the new design — WWDC25](https://developer.apple.com/videos/play/wwdc2025/310/) | Native Mac adoption examples; illustrative background rather than a macOS 27 API contract |

The project-specific rules in this document—destination recovery, immutable batch
settings, publication/completion semantics, Queue Again behavior and local debug
logging—come from the agreed Libro design and implementation, not quotations from
Apple. Revisit this reference when the target OS or our common workflow changes.
