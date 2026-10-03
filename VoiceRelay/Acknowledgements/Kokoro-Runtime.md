# Optional project-local Kokoro inference runtime

VoiceRelay's October 2 development speech adapter executes an explicitly installed
project-local runtime. Model weights and Python distributions are not bundled in
this app or copied from the historical benchmark.

- mlx-audio 0.5.7: MIT, copyright 2024 Prince Canuma.
  https://github.com/Blaizzy/mlx-audio/blob/v0.5.7/LICENSE
- mlx-community/Kokoro-82M-bf16, revision
  a71e4d38b236d968966a2002c4c895dbd12b1c3c: pinned model card declares Apache-2.0.
  https://huggingface.co/mlx-community/Kokoro-82M-bf16/blob/a71e4d38b236d968966a2002c4c895dbd12b1c3c/README.md

Explicit setup retains model-card/license/notice files supplied by the selected
snapshot and installed distribution licenses in `.runtime/kokoro/notices/`.
`inventory.json` records distribution names, versions, license metadata and copied
license files. Additional dependencies include MLX, Misaki, spaCy, eSpeak/G2P,
SoundFile, NumPy and Torch; their licenses must be reviewed independently.

This notice is not a complete redistribution clearance. Packaging an interpreter,
Python dependencies, G2P/eSpeak components, model and voices requires a complete
license/source/notice review and signed relocation validation before distribution.
See `docs/KOKORO_PROVIDER.md` for the development boundary and operator gates.
