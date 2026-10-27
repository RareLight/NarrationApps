# Standalone Swift narration benchmark

Follow ../../AGENTS.md and ../../docs/TTS_MODEL_BENCHMARK_PLAN.md. This is developer
tooling. Keep the host/fixture tier free of MLX; models run in an offline owned
worker, serially, using the shared background inference lease. No product settings,
catalogs, workers, defaults or production memory budgets change here.

Use `bash scripts/test.sh` for isolated synthetic tests. Real model preparation and
runs are separate explicit commands; never install models as part of ordinary tests.
Keep all assets, audio and operator preferences in ignored .local storage. Never
normalize or alter generated PCM. Cold/warm variants are performance measurements,
not listening entrants. Human bracket and blind preferences must remain unfilled
until the operator supplies them.

The scoring app is server-free local HTML/JavaScript. `Web/bracket-template.html`
is source; only the generated run-folder `bracket.html` is directly usable.
Keep names and original
audio paths outside its payload; the separate identity file is selected only for
an explicit reveal after completion. Check JavaScript advancement against Swift
using the JavaScriptCore fixtures. Browser progress is not canonical bracket.json
until its exported history passes the Swift importer; preserve stale-edit guards.
