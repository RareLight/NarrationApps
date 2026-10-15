#!/bin/bash
set -euo pipefail
worker_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
# Use the same resolved input that Xcode grants to this phase's sandbox.
cp "$SCRIPT_INPUT_FILE_0" "$worker_dir/mlx.metallib"
# Helpers is a code directory; Metal binaries there need their own signature.
if [[ "$CODE_SIGNING_ALLOWED" == YES ]]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$worker_dir/mlx.metallib"
fi
