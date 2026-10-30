# Long-form phrasing listening results — October 30, 2026

The operator completed all five blind pairs for the original multi-paragraph
product-pipeline corpus. The submitted choices matched the generated run identity
and pair IDs. Exact notes, source-file hash and interpreted results are retained
privately alongside the run under `operator-feedback/`; earlier model-bracket
choices and generated recordings are unchanged.

This is listening evidence for this passage and these voices. It is not broad
pronunciation acceptance, a new overall model ranking, GUI/recognition acceptance,
or authorization recorded as production-default activation.

**Subsequent operator decision, October 30:** the operator explicitly requested
mandatory semantic phrasing for Kokoro, removal of its switch and correction of
compound-word pauses. This is now implemented; the other engines retain their
optional experiments. The table below preserves the original listening evidence.
See [current behavior](LONGFORM_QUALITY.md).

| Pair | Model / voice | Choice | Operator observation |
| --- | --- | --- | --- |
| 1 | Kokoro / Heart | Semantic phrasing (B) | Better flow and fewer pauses; contextual “read” still problematic |
| 2 | Soprano | Same | Rushed, insufficient natural pauses and inconsistent tone |
| 3 | Qwen3-TTS 1.7B / Ryan | Same | Slow/hesitant delivery despite good pronunciation overall |
| 4 | Chatterbox Turbo / default | Same | Better prosody than preceding voices, successful “read” contexts; “Celsius”/“PM” errors and insufficient paragraph separation |
| 5 | Orpheus 3B / leah | Same | Strongest prosody in this passage, appropriate paragraph pauses; “kilograms” error |

The operator reported that every voice failed the contrasting “lead” readings.
“Good pronunciation” for an individual voice is therefore relative, not a claim
that all target words were correct. Orpheus's A was the semantic candidate and B
the accepted policy; the other four pairs used the reverse assignment.

## Interpretation

Only Kokoro showed a reported preference for semantic phrasing. Its prepared
utterance count fell from nine to seven while total duration stayed close
(83.92 to 83.08 seconds), consistent with the observation about flow rather than
a large global speaking-rate change. The other voices also had fewer synthesis
splits, but the operator reported no A/B preference. Bigger chunks alone do not
establish a quality benefit for these voices on this corpus.

Ryan's recordings lasted 117–121 seconds; the other voices ranged from 70.5–93.9
seconds. This supports investigating the reported pacing difference, but total
duration does not identify its cause or distinguish slow articulation from extra
pauses, repetitions or other generation behavior. This comparison did not measure
content correctness with ASR. Do not infer a runtime/inference speed from these
playback durations or replace the earlier model/voice bracket with this result.

Kokoro and the larger models used the same structural pause schedule in both
preparations: a 0.28-second paragraph target counting only exact-zero edge frames,
with model near-silence untouched. Soprano's legacy baseline does not insert
structural gaps; its candidate uses that schedule, so its comparison also changes
pause assembly. The differing reports across voices favor model-specific paragraph
pause experiments, preserving Kokoro's improved flow and Orpheus's satisfactory
separation. These are proposed experiments, not new accepted pause durations.

## Next decisions and experiments

1. Semantic phrasing is a candidate for Kokoro-only default activation, supported
   by this preference. Leave other engines on their accepted policies absent a
   demonstrated quality benefit. No defaults were changed by importing results.
2. Prioritize contextual pronunciation, with explicit contrasting read/lead cases.
   Audit contextual frontend output before choosing a resolver. A blanket global
   word substitution would damage the other meaning; preserve abstention and
   source mappings. Forced-name rules alone do not resolve contextual ambiguity.
3. Isolate unit/time spoken forms for Chatterbox and Orpheus. The optional extra
   English expansions were off in this segmentation comparison. Test source,
   prepared spoken text and corrected audio separately; expanding “kg” is not by
   itself proof that “kilograms” will be pronounced correctly.
4. Compare only paragraph timing for voices with insufficient separation. Avoid
   changing internal sentence pauses or applying one new gap to all models.
5. Investigate Ryan's product-path pacing separately from segmentation and earlier
   model-bracket evidence, including instructions, generation parameters and
   repeated seeds/passages. Keep the captured baseline and reference audio levels;
   do not silently time-stretch speech or infer a model-wide quality verdict.

See the [implementation plan](LONGFORM_QUALITY_IMPLEMENTATION_PLAN.md),
[quality guide](LONGFORM_QUALITY.md) and B09 in the
[operator checklist](OPERATOR_VALIDATION.md) for the remaining acceptance boundary.
