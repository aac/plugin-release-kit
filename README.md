# plugin-release-kit

The canonical mechanism + playbook for releasing agent-tools as installable
plugins. Tool repos reference this kit instead of each keeping their own copy of
the release process — one source of truth, so the rules can't drift.

It holds:

- **`bin/verify-release`** — an executable conformance check. Every release rule
  in the playbook is an assertion here, so drift becomes a failing check instead
  of a hand-rediscovered stale path.
- **`bin/stage-binaries`** — cross-compiles a binary tool's per-arch binaries +
  launcher into its tracked `bin/`, version-stamped and darwin-signed. `/plugin
  install` (Claude and Codex) installs from the default branch, so the binary must
  be committed there. Run by the prepare-release workflow.
- **`bin/stage-payload`** — curates the shipped plugin **payload** into a `dist/`
  subtree, copying only the allowlisted tracked files (`bin/`, `skills/`, manifests,
  `README`, `LICENSE`, ...) so the install ships a product, not the whole dev work tree.
  Fail-closed: anything unlisted (internal docs, drafts, operator artifacts) is never
  copied. The allowlist lives once in `bin/lib-payload.sh`, shared with `verify-release`
  [16]. See the playbook's *Curated payload* section.
- **`.github/workflows/release-plugin.yml`** — the reusable prepare-release
  pipeline (`workflow_dispatch`-triggered): bump version → build + stamp + sign →
  verify → **commit to the default branch**. Each tool's `release.yml` is a thin
  caller. No tags, no GitHub Releases, no tarballs.

(Plus `bin/lib-binaries.sh` — the single definition of the arch list + launcher
shared by `stage-binaries` and `verify-release` — and version helpers.)

The rules these enforce live in **[`playbook/release-playbook.md`](playbook/release-playbook.md)** — the single canonical spec.

## Verify a tool repo

```sh
bin/verify-release --repo <path-to-tool-repo>
```

Exit 0 = release-ready; exit 1 = at least one FAIL. Run it during release prep
and as a CI gate.

### Privacy model

The verifier is public and contains **no personal data**. Absolute personal
paths (`/Users/<x>`, `/home/<x>`) are caught by generic patterns. Personal proper
nouns (maintainer handle, private command/project names) are matched against a
denylist **injected at runtime** — never committed here:

```sh
bin/verify-release --repo <path-to-tool-repo>
# explicit override: --denylist <file>, or PLUGIN_KIT_DENYLIST=<file>
```

Resolution order: `--denylist` → `$PLUGIN_KIT_DENYLIST` → the per-machine default
`~/.config/plugin-release-kit/denylist` (`$XDG_CONFIG_HOME` honored). So on a
machine that has the default file, agents need not be handed a path — it's found
automatically. The denylist is a newline-separated list of terms (`#` comments
allowed) and is **never committed** (it's personal). With none found anywhere, the
proper-noun check is skipped with a warning; everything else still runs.

## Wire the release pipeline into a tool

In the tool repo's `.github/workflows/release.yml`:

```yaml
name: Release
on:
  workflow_dispatch:
    inputs:
      version:
        description: "x.y.z"
        required: true
jobs:
  release:
    # SECURITY: this reusable workflow COMMITS to your default branch, so it runs
    # with `contents: write`. Pin it to an immutable commit SHA, never a moving
    # branch/tag (`@main`/`@v1`), so a supply-chain change can't gain write access
    # to your repo. Bump the SHA deliberately when adopting kit changes.
    uses: aac/plugin-release-kit/.github/workflows/release-plugin.yml@<commit-sha>
    with:
      tool: <tool>                    # optional; defaults to the repo name
      version: ${{ inputs.version }}
    permissions:
      contents: write
```

Triggered on demand, this bumps the version across the manifests, builds +
version-stamps + ad-hoc-signs the per-arch binaries into `bin/`, gates on
`verify-release`, and commits the result to your default branch. That commit (with
its bumped `version`) is the release — `/plugin install`/`update` and
`codex plugin marketplace upgrade` pull it. No tags, no GitHub Releases.

## License

Apache-2.0. See [LICENSE](LICENSE).
