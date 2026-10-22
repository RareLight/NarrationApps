# Native dependency ownership

Pinned source preparation, patches, codec building and redistribution notices now belong to [the shared packages](../../docs/DEPENDENCIES.md). Both apps embed their own signed helpers and resources. Use root `bash scripts/develop.sh setup --resolve` for coordinated setup, or run
`bash macos/scripts/prepare-dependencies.sh` from `Libro/` for standalone source
preparation. Neither command installs speech models.
