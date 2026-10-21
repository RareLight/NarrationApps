# NarrationApps repository layout

```text
NarrationApps/                    # one Git repository, main
  .git/
  LICENSE
  AGENTS.md  README.md  CONTRIBUTING.md
  DevelopmentBaseline.json       # component paths and tested toolchain
  docs/
  scripts/                       # cross-app checks, setup and packaging support
  NarrationApps.xcworkspace/
  swift-packages/                 # SwiftNarration; no nested .git
    Package.swift  Package.resolved
    AppPresentation/             # independent zero-dependency Swift package
    Sources/  Tests/
    scripts/  Patches/  DependencyTests/  ThirdPartyNotices/
  Libro/                         # tracked app sources; no nested .git
    macos/
  VoiceRelay/                    # tracked app sources; no nested .git
  .local/                        # ignored private evidence/recovery
  .build/                        # ignored generated build state
```

The [monorepo migration record](MONOREPO_MIGRATION.md) describes imported history,
privacy filtering, original Git metadata recovery and publication status. Use Git
from this root or an app directory: all maintained changes belong to the same
repository. Models, credentials, personal documents, library state and generated
media remain private and ignored. Do not copy live data into fixtures.

`swift-packages` retains its name and SwiftPM identity. There is no root
Package.swift and no copied shared source in either app. Standalone app projects
still work with their sibling packages; the apps do not depend on each other.
Open only `NarrationApps.xcworkspace` for concurrent Xcode development. Build Both
Apps compiles both apps in Debug or Release; individual app schemes own Archive.
See [workspace details](PACKAGE_BOUNDARIES.md).

Run `bash scripts/check.sh` for layout, docs, tooling, package/app fixtures and
isolated packaging tests. Layout checks require app sources tracked by root with
no nested app Git metadata. Use explicit `setup --resolve` for pinned native
preparation/resolution. Never copy `.build`, DerivedData or SwiftPM workspace
state between checkouts; regenerate them using the maintained scripts.

## Migration validation and archival gate

The October 16 migration moved maintained native Swift code into this parent and
regenerated its dependency/build state. Operator build/launch smoke was accepted;
feature, listening, Keychain and service acceptance remain separate. The later Git
unification changes repository ownership while preserving these source paths.

Original sibling folders outside NarrationApps were not removed or edited. They
may contain legacy/private material omitted from the active checkout. Archive
those folders only after confirming the current workspace, model selection,
voice playback and library/output settings, and updating editor project folders.
Use normal team signing for Keychain/server checks. The consolidated
[operator checklist](OPERATOR_VALIDATION.md) owns acceptance; ad-hoc builds do not
establish live-account behavior. No settings or Keychain data are migrated here.
