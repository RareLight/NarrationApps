#!/bin/bash
set -euo pipefail
worker_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
cp "$BUILT_PRODUCTS_DIR/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" "$worker_dir/mlx.metallib"
# Helpers is a code directory; Metal binaries there need their own signature.
if [[ "$CODE_SIGNING_ALLOWED" == YES ]]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$worker_dir/mlx.metallib"
fi
