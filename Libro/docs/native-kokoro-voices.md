# Native Kokoro voice recommendations

Updated October 9, 2026, at the user's request. This supersedes the native plan's
original Aoede default. The GUI/native speech settings now default to **Heart
(`af_heart`)**, with speed **1.1** unchanged. Python CLI defaults are unchanged.

## Research and policy

Use Kokoro's published **Overall Grade**, which combines the estimated quality
and quantity of training data. It is recommendation guidance, not an objective
listening leaderboard. Personal preference, text length, accent and delivery
can change which voice works best for a document.

Primary sources checked:

- [Hexgrad's official VOICES.md](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md),
  last file revision [c3327e9bac3dbe55779397bfa82de0f8806fb3bc](https://huggingface.co/hexgrad/Kokoro-82M/blob/c3327e9bac3dbe55779397bfa82de0f8806fb3bc/VOICES.md).
- [The MLX bf16 model's voice table](https://huggingface.co/mlx-community/Kokoro-82M-bf16/blob/main/VOICES.md),
  which agrees with those English grades. The app continues using its existing
  pinned model/voice tensors; no model revision or assets changed.

An older official revision rated Aoede B+, but the current table rates it C+.
Use the current table consistently rather than mixing revisions. There is no
supported strict quality ordering inside a grade: ties use alphabetical names.
Libro marks the four strongest English grades (A through B-) **Recommended**.
This threshold is Libro's presentation choice based on the published grades.

| Overall grade | Voices in menu order | Recommended |
|---|---|---|
| A | Heart | Yes |
| A− | Bella | Yes |
| B− | Emma, Nicole | Yes |
| C+ | Aoede, Fenrir, Kore, Michael, Puck, Sarah | |
| C | Alloy, Fable, George, Isabella, Nova | |
| C− | Sky | |
| D+ | Lewis | |
| D | Alice, Daniel, Echo, Eric, Jessica, Liam, Lily, Onyx, River | |
| D− | Santa | |
| F+ | Adam | |

## UI and runtime behavior

- Both main-window and next-batch voice menus use the same ranking. Recommended
  choices have a native star icon under a Recommended heading, above a divider.
  At the user's follow-up request, menu labels contain names only, with no
  letter grades or heading for the remaining voices.
  The selected voice's help explains its ID, grade and basis.
- Only available voices appear. Lower-rated voices stay selectable. Future
  ungraded voices are retained last, alphabetically, without a recommendation.
- Friendly names, grades and stars never change the voice ID in worker requests.
  Explicit voice choices remain intact; starting the app defaults to Heart.
- Local asset lookup and reuse defaults follow the same native default. Missing
  Heart assets require explicit preparation, with no silent voice substitution.
- Voice ranking is bundled metadata, with no network lookup during app use.
  Review these grades when updating Kokoro and revise the fixture expectation
  deliberately. No audio normalization, gain adjustment or scheduler change is
  involved.

## Validation

- The full native fixture gate passed **69 tests, zero failures**, including all
  28 graded English voices, alphabetical ties, recommendation membership,
  partial/ungraded available lists, native default and explicit Aoede preservation.
  Log: `macos/.build/voice-ranking-final-tests.log`.
- The rebuilt native acceptance harness generated Kokoro with its new Heart
  default and Soprano with networking blocked and SDK/global caches isolated.
  Both published finite/nonzero audio with bit-identical model samples in WAV.
  Heart: 24 kHz, 177,600 frames; Soprano: 32 kHz, 274,432 frames.
  Log: `macos/.build/heart-default-offline.log`; files/results under
  `macos/.build/acceptance/heart-default/`. This is mechanical real speech,
  not subjective listening acceptance.
- Initial native menu inspection verified all ranked voices, star icons and
  explicit Aoede selection retaining `af_aoede`. The user then asked to remove
  letter grades and the second section heading, retaining Recommended, stars
  and the divider. Final menu/build results follow below.

- Final Computer Use inspection verified the requested names-only menu:
  Recommended above starred Heart/Bella/Emma/Nicole, a visible divider, then
  every remaining voice in researched order without another heading. Relaunch
  selected Heart and validated its local assets. Existing output format and
  destination preferences stayed unchanged. Main and next-batch menus share
  the same `NarrationControls` implementation.
- Final Debug build passed (`macos/.build/voice-menu-final-debug-build.log`),
  strict/deep bundle signature verification passed, and its embedded worker
  reported Metal ready. Final Release also passed
  (`macos/.build/voice-menu-final-release-build.log`), with strict/deep bundle
  verification and Metal-ready worker probe. `git diff --check` passed.
