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

A `"source": "./"` marketplace installs **tracked files only**, and `/plugin
install` **never fetches GitHub Release assets** — it checks out the repo at a
ref. So the binary a plugin's MCP server runs must be **committed in the repo**;
a binary built only into a release zip is unreachable to the installer, and a
fresh user gets a non-functional MCP server. The mechanism:

- **Committed `bin/`.** A binary tool commits, under tracked `bin/`, a
  `uname`-based launcher (`bin/<tool>`) plus one binary per arch
  (`bin/<tool>-<os>-<arch>` for `darwin/amd64 darwin/arm64 linux/amd64
  linux/arm64`). `bin/stage-binaries --repo . --tool <tool>` cross-compiles all
  arches, **ad-hoc-codesigns the darwin binaries** (an unsigned `darwin/arm64`
  binary is SIGKILL'd at launch — so staging must run on macOS), and writes the
  launcher; the maintainer commits the result **before tagging**. The arch list
  and launcher have a single definition in `bin/lib-binaries.sh`. [check 7]
- **Per-host MCP config — the two hosts can't share one command string.** MCP-
  server startup does **not** get the plugin's `bin/` on `PATH` (that mechanism is
  Bash-tool-only), so a bare command name never resolves. Each host references the
  bundled launcher differently, so a binary tool ships **two** server definitions:
  - **Claude** auto-discovers root `.mcp.json`; its command is
    `${CLAUDE_PLUGIN_ROOT}/bin/<tool>` — the documented way for a plugin to invoke
    its own binary; Claude expands `${CLAUDE_PLUGIN_ROOT}` to the plugin root.
  - **Codex** does **not** auto-discover and does **not** expand
    `${CLAUDE_PLUGIN_ROOT}`. It loads the file `.codex-plugin/plugin.json`'s
    `mcpServers` points at, and resolves a bundled binary via a **relative
    `command` + `cwd` joined to the plugin root**. So Codex gets its own config —
    `.codex-plugin/mcp.json` with `command: "./bin/<tool>"`, `cwd: "."` — and
    `.codex-plugin/plugin.json` points `mcpServers` at `./.codex-plugin/mcp.json`
    (not the Claude `.mcp.json`). Empirically validated on codex 0.141.0: the
    bundled binary launches from the plugin cache root with no PATH dependency.
  - `verify-release` [check 7] asserts both: root `.mcp.json` uses
    `${CLAUDE_PLUGIN_ROOT}/bin/<tool>`, and the Codex-pointed config uses
    `./bin/<tool>` + `cwd: "."` (and **fails** if Codex's pointer aims back at the
    Claude `.mcp.json`). [check 7]
- **The release workflow delivers the fallbacks, not the install.** `bin/build-
  plugin.sh` still assembles `<tool>-plugin.zip` — but now purely from `git
  archive` of the committed tree (including `bin/`, whose executable bits and
  ad-hoc signatures `git archive` preserves), so the zip is a faithful copy of
  the installed plugin rather than a separately-built artifact. The zip and the
  GoReleaser tarballs (the `go install` / `curl | sh` path) are convenience/
  fallback downloads; the *install* path is the committed tree. The reusable
  `.github/workflows/release-plugin.yml` runs on every `vX.Y.Z` tag; each tool's
  `release.yml` is a thin caller that `uses:` it — **pinned to an immutable
  commit SHA**, never a moving branch/tag, since it runs with `contents: write`
  (CI/CD supply-chain hygiene). [check 7]
  - Because the pin is immutable it does **not** auto-update. `verify-release`
    [check 7] **warns** when a tool's pinned kit SHA is behind the kit's `HEAD`,
    so drift surfaces every time you verify a tool. Adopt kit updates by bumping
    the pin **deliberately**. (The signal compares against your *local* kit
    checkout's `HEAD`, so keep it `git pull`-current for the count to be accurate.)
- `verify-release` [check 7] runs the committed binary for the verifier's own
  host (`<tool> version`) as a smoke test — catching a corrupt/wrong-arch commit,
  a broken launcher, or (on macOS) an unsigned binary that would SIGKILL.

**Size tradeoff:** the per-arch binaries are committed raw/uncompressed (~tens of
MB across four arches), and each release re-commits them, so they accrue in git
history. UPX/LFS optimization is a **deliberate deferred follow-up**, not done
here — correctness (a working install) first.

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

- **Privacy repave — only when `check-history` flags leaked history.** Squashing/
  recreating from a clean snapshot so old personal-data-bearing commits don't go
  public. A one-time remediation for repos developed before the scrub discipline;
  a tool built verifier-green from commit one never needs it.
- **Flip to public** and announce — always a deliberate human call.

Order when a repave is needed: content pass (verifier green) → `check-history` →
clean snapshot → recreate remote → push → flip public → announce.

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

4. **Stage binaries (binary tools only).** `<kit>/bin/stage-binaries --repo .`
   cross-compiles every arch into tracked `bin/`, ad-hoc-signs the darwin
   binaries, and writes the launcher. **Run on macOS** (darwin signing). Commit
   the staged `bin/` **before** tagging — the committed tree *at the tag* is what
   ships, so a tag taken before this captures stale/absent binaries. Re-run
   `verify-release` after committing so the execute smoke test runs against the
   freshly-staged binary. Skill-only tools skip this step.

5. **Tag.** `git tag vX.Y.Z -m "…" && git push origin vX.Y.Z`. The release
   workflow builds the binary tarballs + the plugin zip (now a `git archive` of
   the committed tree, binaries included) and attaches them to a **draft** GitHub
   Release.

6. **Confirm artifacts** on the draft release: 4 tarballs + `checksums.txt` +
   `<tool>-plugin.zip`, and the zip carries `bin/` (launcher + per-arch
   binaries) + `skills/` + `.claude-plugin` + `.codex-plugin` + `.mcp.json`.

7. **History check (before a first public release):**
   `<kit>/bin/check-history --repo .`. Clean (the normal case for a tool built
   verifier-green from commit one) → no repave; go to 8. Leaks (a legacy repo
   developed before the scrub discipline) → a **one-time privacy repave** is
   needed (squash from a clean snapshot; see *What's the maintainer's*) — surface
   it as an ask. The working-tree checks ([8]/[9]) stop new leaks at the source,
   so this is remediation for the past, not a standing step.

8. **HUMAN GATE — flip to public:** going public is a deliberate "ready for the
   world" call. The agent surfaces it as an ask; it does not change repo
   visibility itself (nor rewrite history when a repave is needed — both are
   destructive on a published repo).

9. **Publish:** flip GoReleaser `draft: true → false` once the first tagged run is
   validated end to end, then publish.

For a still-private tool, steps 1–7 are the whole loop; the agent escalates the
human gate (8) as an ask and stops there.
