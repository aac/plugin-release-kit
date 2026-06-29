# plugin-release-kit

The canonical mechanism + playbook for releasing agent-tools as installable
plugins. Tool repos reference this kit instead of each keeping their own copy of
the release process — one source of truth, so the rules can't drift.

It holds:

- **`bin/verify-release`** — an executable conformance check. Every release rule
  in the playbook is an assertion here, so drift becomes a failing check instead
  of a hand-rediscovered stale path.
- **`bin/stage-binaries`** — cross-compiles a binary tool's per-arch binaries +
  launcher into its tracked `bin/` (ad-hoc-signing darwin), for the maintainer to
  commit before tagging. `/plugin install` only delivers tracked files, so the
  binary must be committed, not just built into a release zip.
- **`bin/build-plugin.sh`** — assembles a self-contained `<tool>-plugin.zip` from
  `git archive` of the committed tree (skill + manifests + the committed `bin/`).
- **`.github/workflows/release-plugin.yml`** — a reusable (`workflow_call`)
  release pipeline. Each tool's `release.yml` is a thin caller.

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
  push:
    tags: ['v*']
jobs:
  release:
    # SECURITY: this reusable workflow runs with `contents: write`. Pin it to an
    # immutable commit SHA, never a moving branch/tag (`@main`/`@v1`), so a
    # supply-chain change can't gain write access to your repo. Bump the SHA
    # deliberately when adopting kit changes.
    uses: aac/plugin-release-kit/.github/workflows/release-plugin.yml@<commit-sha>
    with:
      tool: <tool>   # optional; defaults to the repo name
    permissions:
      contents: write
```

On a `vX.Y.Z` tag this builds the binary tarballs (via the tool's own
`.goreleaser.yml`) and the self-contained plugin zip, attaching both to a draft
GitHub Release.

## License

Apache-2.0. See [LICENSE](LICENSE).
