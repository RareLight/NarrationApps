# Maintaining documentation

Documentation should answer the reader's immediate question, then link to deeper
detail. This policy was introduced with the October 21, 2026 review. It covers
project-authored Markdown and agent instructions; original dependency licenses,
notices and upstream documentation remain unmodified.

## Readers and ownership

| Reader | Starting point | What belongs there |
| --- | --- | --- |
| App user | Root/app READMEs; VoiceRelay user guide | Requirements, setup, visible actions, defaults, data consequences and recovery |
| Power user | Narration guide and topic references | Matching/cleanup limits, storage, captured settings, encoding and verification details |
| Developer | CONTRIBUTING and DEVELOPMENT | Exact working directories, prerequisites, safe commands, test scope, signing and evidence |
| Agent | Root and scoped AGENTS.md | Invariants, ownership, workflow constraints and pointers to current state |
| Reviewer/operator | IMPLEMENTATION_STATUS and OPERATOR_VALIDATION | Dated evidence, actual candidate locations and separate manual acceptance |

Root README is the entry point. [docs/README.md](README.md) is the navigation index.
The [architecture](ARCHITECTURE.md) owns cross-app technical contracts; app
architecture guides own their workflows. [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md)
owns current feature state; [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) owns
remaining work. The operator checklist is the single manual checklist. Do not
create competing lists of pending operator checks in app validation pages.

## Keep current guidance distinct from history

An implementation record must say which stages are complete, what later changes
superseded it and where current commands live. Preserve dated observations as dated
observations. Original prompts, old commit IDs, test totals and generated build
paths are not current prerequisites or instructions to restart finished work.
Older original Git IDs may exist only in private migration backups after filtering;
see [migration provenance](MONOREPO_MIGRATION.md).

Do not label an arbitrary old build “latest”. Record the source, configuration,
signing class and verification date. Distinguish an automated build from an app
currently under operator review; never replace the latter as a documentation step.
Private `.local/` reports may be absent on another machine. Public instructions
must work from maintained source and explicit preparation rather than requiring
those reports or private documents.

## Writing and accuracy checks

- Use actual UI labels and explain the result of an action. State defaults and
  what happens to existing jobs, source files and recordings when that matters.
- Put engineering details in the technical reference, not the user's first steps.
  Define unfamiliar terms once; use tables for choices or different data effects.
- State the working directory before commands. Root is the default; package and
  standalone-app commands need an explicit scope. Retain locked dependency flags.
- Verify behavior against relevant source/tests, not just another guide. Distinguish
  implemented behavior, automated evidence, operator acceptance and proposed work.
- Keep setup, normal use, troubleshooting and destructive test procedures separate.
  Do not copy private paths, endpoints, prose, logs or credentials into examples.
- Verify paths before describing them. Preserve intentional compatibility names such
  as `VoiceRelayPrototype` in Application Support and existing preference identities.
- Update agent instructions when repository ownership changes. Do not turn old
  implementation prompts into standing authorization or relax safety constraints.

## Validate a documentation change

From the NarrationApps root:

```sh
bash scripts/check.sh --tier quick
```

This runs static graph/layout/docs checks and isolated development-tool regressions.
For nested guides outside the standard root/app documentation scopes, also run the
existing checker with each relevant directory:

```sh
swift scripts/check-docs.swift swift-packages/AppPresentation
swift scripts/check-docs.swift swift-packages/Tests/Fixtures/Longform
swift scripts/check-docs.swift Libro/macos
swift scripts/check-docs.swift Libro/macos/Design/LibroIcon
swift scripts/check-docs.swift VoiceRelay/icon
```

The checker verifies local Markdown links and heading anchors, not external sites
or the behavior of commands in a code block. Review command arguments against the
scripts without downloading models, mutating a live library, signing into accounts
or launching the apps. Broader builds/tests are needed when source or relevant
contracts change, not merely because a README was rewritten. Documentation checks
are not a fresh GUI, listening, Keychain, WebDAV or distribution acceptance result.
