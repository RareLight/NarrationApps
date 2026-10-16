#!/bin/bash
set -euo pipefail
show_help() {
    printf "Usage: %s 'Text for every voice to narrate'\n" "$0"
    cat <<'HELP'

Regenerate the shared voice samples bundled with Libro and VoiceRelay.
Pass exactly one nonempty text argument. Use single quotes to protect punctuation:

  bash regenerate-voice-samples.sh 'I can narrate your next book. Lets get started!'

In interactive zsh, ! immediately before a closing double quote can trigger
history expansion and leave the shell at a dquote> prompt. Single quotes avoid it.
If your text contains an apostrophe, use double quotes and escape each ! as \!.

Options:
  -h, --help  Show this help without building or generating audio.
HELP
}
if [[ $# -eq 1 && ( "${1-}" == -h || "${1-}" == --help ) ]]; then
    show_help
    exit 0
fi
if [[ $# -ne 1 || -z "${1-}" ]]; then
    show_help >&2
    exit 2
fi
shared_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$shared_root"
bash scripts/prepare-dependencies.sh
swift build --disable-sandbox --product NarrationSpeechWorker --jobs 4
swift build --disable-sandbox --product VoiceSampleGenerator --jobs 4
bin_path="$(swift build --disable-sandbox --show-bin-path)"
exec "$bin_path/VoiceSampleGenerator" "$1"
