# VoiceRelay development

This directory is the canonical root for the Swift/macOS application. Inspect the
engineering brief, implementation plan, and validation record in `docs/` before
extending a slice. Keep the independently testable Swift core shared by the Xcode
app, diagnostic CLI, and Swift package tests.

- Preserve the Python reference and all customized configuration, state, feeds,
  and published audio in their existing locations. Do not copy live data into
  this project or silently adopt its schema. Use explicit isolated fixtures.
- Keep private endpoints, credentials, model assets, and generated artifacts out
  of source control. Retain pinned dependencies and their redistribution notices.
- Provide named, source-local SwiftUI previews with synthetic, inert states.
- The user does not authorize automated computer use. Do not operate the GUI or
  request Accessibility or Screen Recording access. Perform permitted source,
  build, and focused fixture checks; hand off GUI, protected-file, agent-context,
  listening, and device validation to the user with exact commands or steps.
- Report builds, tests, Canvas rendering, GUI behavior, and live acceptance
  separately. Mock tones are pipeline evidence, never speech acceptance.
- Make the smallest complete change, preserve unrelated work, and update focused
  tests when behavior changes. Do not enroll services, upload feeds, migrate live
  state, or cut over hosting as a side effect of build or startup.
