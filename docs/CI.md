# CI readiness and external activation

The candidate is GitHub Actions on a dedicated **self-hosted macOS arm64** runner
with the verified Xcode 27.1/macOS 27 SDK composition. No hosted-runner support for
these frameworks/GPU requirements is assumed. Current provider availability and
the action pin still require official-documentation review before activation:
[runner images](https://github.com/actions/runner-images),
[self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners),
[workflow syntax](https://docs.github.com/en/actions/writing-workflows/workflow-syntax-for-github-actions).
Online verification was not performed without network approval.

The inactive template is [.devin/ci/github-actions.yml](../.devin/ci/github-actions.yml).
It is intentionally not installed under `.github/workflows/`. Local YAML parsing
is structural evidence only, not GitHub schema/provider execution acceptance.
It uses an immutable checkout action revision (v4.2.2); review current support,
upstream identity and security status before activation. No new runtime dependency,
CI resource, secret, remote, billable machine or service was provisioned.

## Activation requires the operator

1. Choose/publish the root remote and make all recorded app commits retrievable.
   Existing checkpoint commits are local; no remote availability is promised.
2. Review official provider/runner and action documentation. Authorize any cost.
   Register a dedicated, access-controlled arm64 runner with
   `narration-xcode-27-1`; do not use the production app user or private libraries.
3. Provide least-privilege source-only access to both recorded app origins through
   a managed SSH agent/known-hosts policy. No credentials enter a URL or repository.
   Do not disable host-key verification. Root's checkout token is not assumed to
   read either independent app repository.
4. Use fresh disposable job workspaces. Setup refuses existing app paths rather
   than resetting them; configure ephemeral runner cleanup outside this workflow.
   Never copy DerivedData or SwiftPM workspace state into another checkout.
5. After review, install the template as `.github/workflows/foundation.yml` and
   explicitly enable `NARRATION_FOUNDATION_CI_ENABLED=true`. Only trusted main
   pushes/manual dispatch run: untrusted PR code must never execute on this runner.
6. Run manual full then release. Inspect ignored `summary.json` and logs on the
   runner; add an authorized artifact-retention policy before relying on remote
   evidence. Neither local template validation nor a skipped job is a CI pass.

## Gate policy

`scripts/ci.sh` delegates to the same DF2 entry points. Ordinary docs/config-only
pushes select quick; source/fixture/check-script changes select full; shared
public/presentation sources, manifests/pins, patches/notices, workspace,
worker/project/build tooling or composition changes select full plus
release. A missing/unknown comparison revision conservatively selects release.
Manual quick/full/release dispatch is explicit. Full/release use locked prepared
sources without automatic updates. Full's preparation is network-denied; native
workers/probes are individually network-denied, separate from setup acquisition.

No cache is shared across jobs/checkouts. Future cache proposals must key Xcode
build, SDK, architecture, absolute checkout path, all lockfiles and patch hashes.
There is no scheduled GUI or product automation and no models are downloaded.
The generic workflow never runs native inference. Native gates require a separately
authorized compatible model-equipped machine, idle apps and serialized GPU work;
use the documented native tier locally rather than pretending hosted CI ran it.
Safari, Keychain, WebDAV, private documents, signing accounts and live feeds remain
operator-owned. Provider activation and real remote results are **pending**.
