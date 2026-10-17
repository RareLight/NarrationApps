#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-lint}"
scope="${2:-all}"
[[ $# -le 2 && ( "$mode" == lint || "$mode" == apply ) ]] || {
    echo 'Usage: bash scripts/format.sh lint|apply [root|Libro|VoiceRelay|all]' >&2; exit 2;
}
case "$scope" in
    root) repositories=("$root") ;;
    Libro|VoiceRelay) repositories=("$root/$scope") ;;
    all) repositories=("$root" "$root/Libro" "$root/VoiceRelay") ;;
    *) echo 'Unknown formatting scope.' >&2; exit 2 ;;
esac
for repository in "${repositories[@]}"; do
    cmp "$root/.devin/swift-format.json" "$repository/.devin/swift-format.json"
    files=()
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        case "$file" in
            /*|../*|*/../*|*/.build/*|*/Fixtures/*|*/Patches/*|*/ThirdPartyNotices/*)
                echo 'Unsafe or excluded format path.' >&2; exit 2 ;;
            scripts/*.swift|swift-packages/Sources/*.swift|swift-packages/Tests/*.swift|macos/Libro/App/*.swift|Sources/VoiceRelayApp/*.swift)
                files+=("$repository/$file") ;;
            *) echo 'Format paths must name maintained Swift source.' >&2; exit 2 ;;
        esac
    done < "$repository/.devin/format-files.txt"
    [[ ${#files[@]} -gt 0 ]] || { echo 'Empty formatting baseline.' >&2; exit 2; }
    if [[ "$mode" == lint ]]; then
        xcrun swift format lint --strict --configuration "$repository/.devin/swift-format.json" "${files[@]}"
    else
        xcrun swift format format --in-place --configuration "$repository/.devin/swift-format.json" "${files[@]}"
    fi
done
