# Releasing an agent-tool as a plugin — canonical playbook

This is the **single source of truth** for how a tool ships as an installable
plugin. It exists so that no tool repo keeps its own copy of these rules — copies
drift, and the drift gets rediscovered one stale path at a time. Each rule below
is enforced by `bin/verify-release` (check numbers in brackets); the playbook is
the prose, the verifier is the executable form. If the two ever disagree, fix
both in the same change.

## The distribution model

**Per-repo self-marketplace, plugin-first.** Each tool repo is its own
single-plugin marketplace. A user installs with:

```
/plugin marketplace add <owner>/<tool>
/plugin install <tool>@<tool>
```

- The repo carries `.claude-plugin/marketplace.json` with `"source": "./"` — it
  publishes itself, not via any shared catalog. [check 1]
- The README leads with this plugin install, before any binary-install fallback.
  [check 3]
- There is **no shared distribution marketplace.** The former
  `agent-tools-release` repo is retired as a distribution path; no tracked file
  may reference it. [check 4]

Binary install (`go install`, `curl | sh install.sh`, release tarball) remains a
documented *fallback*, never the lead.

## Two tool shapes

- **Skill-only** (e.g. surface, reach): the plugin is a skill bundle — manifests
  + `skills/<tool>/`. No binary.
- **Binary-backed** (e.g. ask, act): the plugin must also deliver a compiled
  binary that the skill and the MCP server invoke as a plain command. Most of the
  binary-specific rules below apply only to these.

## Binary-into-plugin delivery

A `"source": "./"` marketplace installs **tracked files only**, and the binary is
gitignored — so a binary tool's plugin would have no working binary unless the
release bundles one. The mechanism:

- `bin/build-plugin.sh` assembles a self-contained `<tool>-plugin.zip`: skill +
  manifests from `git archive` (tracked files only), and for binary tools the
  multi-arch binaries cross-compiled into `bin/` plus a `uname`-based launcher.
- `.github/workflows/release-plugin.yml` (this repo's reusable workflow) runs that
  step on every `vX.Y.Z` tag and attaches the zip to the GitHub Release. Each tool
  repo's `release.yml` is a thin caller that `uses:` it — **pinned to an
  immutable commit SHA**, never a moving branch/tag, since the reusable workflow
  runs with `contents: write` (CI/CD supply-chain hygiene). [check 7]
  - Because the pin is immutable it does **not** auto-update. `verify-release`
    [check 7] **warns** when a tool's pinned kit SHA is behind the kit's `HEAD`,
    so drift surfaces every time you verify a tool — no separate sweep to
    remember. Adopt kit updates by bumping the pin **deliberately**. (The signal
    compares against your *local* kit checkout's `HEAD`, so keep it
    `git pull`-current for the count to be accurate.)
- The binary is **never committed**; `bin/` is gitignored. [check 7]
- `.mcp.json`'s command name equals the binary name, so the plugin-placed binary
  resolves on `$PATH`. [check 7]

The published zip is fully self-contained even though the *build* is shared.

## Manifests and versions

- Both `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json` are valid
  JSON (an inline annotation left in a manifest makes a host reject it). [check 2]
- **Versions are kept in lockstep from one source.** `SKILL.md`'s frontmatter
  `metadata.version` is the canonical version; `.claude-plugin/plugin.json`,
  `.codex-plugin/plugin.json`, and `.claude-plugin/marketplace.json` must all
  match it. Use the kit's `bin/bump-version <v>` to change it everywhere and
  `bin/check-versions` to gate drift — the verifier's [check 2] calls the latter,
  so there is exactly one version mechanism, not a per-repo copy. The Codex
  marketplace is version-less (see Marketplaces). [check 2]
- Claude auto-discovers `skills/` and `.mcp.json`, so `.claude-plugin/plugin.json`
  is minimal. Codex does not auto-discover, so `.codex-plugin/plugin.json` must
  carry explicit component pointers for whatever it bundles — `"skills":
  "./skills/"`, and `"mcpServers": "./.mcp.json"` when shipping MCP. Pointers
  start with `./`, stay inside the plugin root, and must resolve. The `interface`
  block is optional install-surface metadata — recommended for published plugins,
  not required for a valid manifest. [check 11]
- The skill description stays within Codex's 1024-char limit. [check 10]

## Marketplaces: Claude and Codex

A tool repo carries one marketplace file per host:

- **`.claude-plugin/marketplace.json`** — Claude's. `"source": "./"`, per-plugin
  `version` present. [check 1] Codex also reads this as a legacy-compatible
  fallback.
- **`.agents/plugins/marketplace.json`** — Codex's *native* location. Same plugin
  entry, but **version-less** (Codex keeps the version in the plugin manifest);
  entries carry `source`, `policy.installation`, `policy.authentication`, and
  `category`. [check 11]

Source formats (both hosts): repo-root Git is
`{"source":"url","url":"https://github.com/<owner>/<tool>.git"}`; local is
`{"source":"local","path":"./..."}`; Git subdir is
`{"source":"git-subdir","url":"...","path":"./..."}`.

## Content hygiene (the scrub)

The shipped surface must be generic and personal-context-free. Default to
*remove* over *trim* over *keep*.

- **No absolute personal paths** (`/Users/<x>`, `/home/<x>`) in tracked files —
  use repo-relative or generic placeholders. [check 8]
- **No personal proper nouns** — maintainer handle, private slash-command names,
  private project codenames. These are caught by an injected denylist, never a
  hardcoded list (see Privacy model). Author attribution in `LICENSE`/manifests is
  fine and exempt. [check 9]
- **One canonical skill tree.** No second copy (e.g. an untracked `internal/skill/`
  shadowing `skills/<tool>/`). [check 6]
- **No scope-review drafts** left in the tree. `*.revised.md` / `*.annotated.md`
  are working drafts: fold the salvageable content into the canonical file
  (replacing whatever the migration superseded), then delete the draft. [check 5]
- **Untrack internal process docs** — session-handoffs, plan/brief/review rounds,
  dogfood logs — before shipping. They are how the work gets done, not the project
  a contributor consumes. (Surfaced by checks 8/9 flagging tracked `docs/`.)
- `CLAUDE.md` is a thin pointer; build-side guidance ships as `AGENTS.md` (vendor
  -neutral — Codex and others read it; `CLAUDE.md` is Anthropic-specific); personal
  prefs/permissions stay in a gitignored `.claude/settings.local.json`. [check 12]

## Privacy model (for this kit and the tools it checks)

The verifier's logic is public and must contain **zero personal data**:

- Personal *paths* are matched by generic patterns (`/Users/<x>`, `/home/<x>`)
  that never name a person.
- Personal *proper nouns* are matched against a denylist injected at runtime from
  `$PLUGIN_KIT_DENYLIST` or `--denylist <file>`, which live outside any public
  repo. A public reader sees "scans against a configured denylist", never its
  contents.
- The owner/org is *derived* from the target repo's git remote, not hardcoded.
- Tilde-dir conventions (a personal workspace root and the like) are per-user
  judgment and belong in the denylist, not the public path pattern (which would
  also false-positive on legitimate `~/.claude` / `~/.codex` install paths).

## What's the maintainer's, not the agent's

Two steps stay manual:

- **Privacy repave** — squashing/recreating history from a clean snapshot so old
  personal-data-bearing commits don't go public.
- **Flip to public** and announce.

Order: content pass (verifier green) → clean snapshot → recreate remote → push →
flip public → announce.

## Shipping a tool — the release runbook

Agent-run end to end. A human is needed only at the gates marked **HUMAN**;
everything else the agent does itself. Run from the tool repo, with a
`git pull`-current kit checkout. Verification happens here, at release time —
there is no continuous CI gate (it would spend Actions minutes for little gain on
a tool that ships rarely).

1. **Verify.** `PLUGIN_KIT_DENYLIST=<denylist-file> <kit>/bin/verify-release --repo .`
   Any **FAIL** is a release-readiness violation — the message names the rule;
   fix it and re-run until `0 FAIL`.

2. **Drift.** If check [7] **WARNs** that the pinned kit SHA is behind HEAD:
   review what changed — `git -C <kit> log <pinned>..HEAD` — and **bump
   deliberately** only if a change matters to this tool (edit the SHA in
   `.github/workflows/release.yml`, commit, re-verify). If it doesn't matter,
   leave it; the WARN is non-fatal. Never auto-bump without reading the diff —
   that re-introduces the supply-chain risk the SHA-pin prevents.

3. **Version.** Confirm `metadata.version` in `SKILL.md` is the intended release
   version (`<kit>/bin/bump-version <v> --repo .` to change it everywhere; add the
   matching `CHANGELOG.md` entry). `<kit>/bin/check-versions --repo .` must be clean.

4. **Tag.** `git tag vX.Y.Z -m "…" && git push origin vX.Y.Z`. The release
   workflow builds the binary tarballs + the self-contained plugin zip and
   attaches them to a **draft** GitHub Release.

5. **Confirm artifacts** on the draft release: 4 tarballs + `checksums.txt` +
   `<tool>-plugin.zip`, and the zip carries the multi-arch binary + launcher +
   `skills/` + `.claude-plugin` + `.codex-plugin` + `.mcp.json`.

6. **HUMAN GATE (first public release only):** the privacy repave + flip-to-public
   (see *What's the maintainer's* above). The agent surfaces these as asks and
   stops; it does not repave history or change repo visibility itself.

7. **Publish:** flip GoReleaser `draft: true → false` once the first tagged run is
   validated end to end, then publish.

For a still-private tool, steps 1–5 are the whole loop; the agent escalates step 6
as an ask and stops there.
