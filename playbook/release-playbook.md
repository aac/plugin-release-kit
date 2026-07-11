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
- The README leads with this plugin install. [check 3]
- There is **no shared distribution marketplace.** The former
  `agent-tools-release` repo is retired as a distribution path; no tracked file
  may reference it. [check 4]

**The plugin is the only distribution.** There is no standalone binary path —
no `go install`, no `curl | sh install.sh`, no release tarballs, no GitHub
Releases. A user installs the plugin or builds from source themselves. (Dropping
the standalone path removed each tool's `.goreleaser.yml`, `install.sh`, and the
tarball CI — dead weight once the plugin carries the binary.)

## Two tool shapes

- **Skill-only** (e.g. surface, reach): the plugin is a skill bundle — manifests
  + `skills/<tool>/`. No binary.
- **Binary-backed** (e.g. ask, act): the plugin must also deliver a compiled
  binary that the skill and the MCP server invoke as a plain command. Most of the
  binary-specific rules below apply only to these.

## Binary-into-plugin delivery

Both Claude (`/plugin install`) and Codex install a plugin from the repo's
**default branch** — they check out the branch HEAD (Claude) / clone it (Codex),
and **never fetch GitHub Release assets or match git tags**. So the binary a
plugin's MCP server runs must be **committed in the repo on the default branch**;
a binary built only into a release artifact is unreachable to the installer, and
a fresh user gets a non-functional MCP server. The mechanism:

- **Committed `bin/`, built in CI.** A binary tool commits, under tracked `bin/`,
  a `uname`-based launcher (`bin/<tool>`) plus one binary per arch
  (`bin/<tool>-<os>-<arch>` for `darwin/amd64 darwin/arm64 linux/amd64
  linux/arm64`). `bin/stage-binaries` cross-compiles all arches, **version-stamps**
  them (see below), **ad-hoc-codesigns the darwin binaries** (an unsigned
  `darwin/arm64` binary is SIGKILL'd at launch — so it runs on macOS), and writes
  the launcher. It is run by the prepare-release CI workflow, which commits the
  result to the default branch — **nothing is built on anyone's laptop**. The arch
  list and launcher have a single definition in `bin/lib-binaries.sh`. [check 7]
- **Version-stamped at build.** `metadata.version` (SKILL.md) is the single
  source. Since install reads the committed tree and there is no release-time
  rebuild, the committed binaries are stamped at build via
  `-ldflags -X <module>/internal/version.Binary=<metadata.version>`
  (`<module>` from `go.mod`; override the var path with `$STAGE_VERSION_VAR`). An
  unstamped binary reports `dev`; a wrong ldflag path is silently ignored by the
  linker — so [check 7]'s smoke test asserts the committed binary **reports
  `metadata.version`**, failing a `dev`/stale stamp before it ships. [check 7]
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
- **The prepare-release workflow IS the release.** The reusable
  `.github/workflows/release-plugin.yml` is triggered **on demand**
  (`workflow_dispatch` with a `version` input) — not by a tag. On a macOS runner
  it: bumps the version across the manifests, runs `stage-binaries` (build +
  stamp + sign), runs `verify-release` as a gate, then **commits the result to
  the default branch**. That commit, with its bumped `version` field, is what
  Claude `/plugin update` and `codex plugin marketplace upgrade` detect. There is
  no tag, no GitHub Release, no artifact to attach. Each tool's `release.yml` is a
  thin caller that `uses:` the reusable workflow — **pinned to an immutable commit
  SHA**, never a moving branch/tag, since it commits to your default branch with
  `contents: write` (CI/CD supply-chain hygiene). [check 7]
  - Because the pin is immutable it does **not** auto-update. `verify-release`
    [check 7] **warns** when a tool's pinned kit SHA is behind the kit's `HEAD`,
    so drift surfaces every time you verify a tool. Adopt kit updates by bumping
    the pin **deliberately**. (The signal compares against your *local* kit
    checkout's `HEAD`, so keep it `git pull`-current for the count to be accurate.)
- `verify-release` [check 7] runs the committed binary for the verifier's own
  host (`<tool> version`) as a smoke test — catching a corrupt/wrong-arch commit,
  a broken launcher, an unsigned binary that would SIGKILL (on macOS), or a
  `dev`/stale version stamp (it asserts the report equals `metadata.version`).

**Size tradeoff:** the per-arch binaries are committed raw/uncompressed (~tens of
MB across four arches), and each release re-commits them, so they accrue in git
history. UPX/LFS optimization is a **deliberate deferred follow-up** — correctness
(a working install) first.

## Curated payload — ship a product, not the work tree

A `"source": "./"` marketplace installs **every git-tracked file** of the repo — the
whole dev work tree (`cmd/`, `internal/`, `.github/`, `Makefile`, `docs/`, `scripts/`,
`AGENTS.md`, drafts, operator artifacts), not a curated product. That is a **hygiene**
problem, not a size one:

- **Allowlist beats denylist for leak containment.** The denylist (checks [8]/[9])
  blocks *known-bad* terms; an allowlisted payload structurally prevents shipping
  *anything unlisted*, including future internal artifacts the denylist has never heard
  of. This is the act-aa46c3 class: an internal `docs/*.md` that carries no denylisted
  token slips past [8]/[9] (check [14] only *WARNs* it) but can **never** enter an
  allowlisted payload. Structural, not reactive.
- **Smaller agent-readable surface.** These are agent-native tools; agents auto-read the
  plugin dir — stray `scripts/`/`Makefile`/drafts are misread/execute risk.
- **The install is the interface.** It should read as a product, not a checkout.

**Mechanism — `stage-payload` → a curated `dist/`.** `bin/stage-payload` copies **only
allowlisted tracked files**, preserving structure, into a `dist/` subtree; the
marketplace source then points the install at that subtree
(`{"source":"local","path":"./dist"}` or the `git-subdir` form) instead of `"./"`. It is
the sibling of `stage-binaries`: `stage-binaries` produces the committed `bin/` (compiled
artifacts), `stage-payload` produces the committed `dist/` (the shipped tree, which
*includes* a copy of `bin/`). **Fail-closed by construction**: the default verdict for
any path is *exclude*; only an explicit allowlist match ships. The allowlist lives once
in `bin/lib-payload.sh`, shared with `verify-release` [16] so producer and verifier can't
drift. [check 16]

**The minimum allowlist** (`lib-payload.sh`): `bin/`, `skills/`, `.mcp.json`,
`.claude-plugin/`, `.codex-plugin/`, `.agents/`, `README`, `LICENSE*`, `SECURITY.md`,
`CHANGELOG.md`. A tool that genuinely ships a doc or asset in its install adds it with
`--payload-allow "docs/spec.md,assets/*"` / `$PLUGIN_KIT_PAYLOAD_ALLOW` — the default
stays minimal. Note `docs/spec.md` is check-[14]-*public* (may be committed) but not
*product* (does not install) — the two allowlists are deliberately distinct.

**`verify-release` [check 16]** enforces this without a native host `files` field:

- **Completeness (always on).** Every load-bearing file a tool ships — manifests, every
  `skills/**/SKILL.md`, `.mcp.json`, the Codex `mcpServers` pointer target, the `bin/`
  launcher + per-arch binaries — must be *inside* the allowlist, else the curated install
  would drop it. **FAIL.** The load-bearing set is derived from the same signals the other
  checks use, never a per-tool literal.
- **Subset (adopted tools).** Once the source points at `./dist`, that tree must be a
  subset of the allowlist — a stray file would ship. **FAIL.** [check 1] accepts the
  curated-dist object source shape so adoption isn't self-blocked.
- **Surface.** The excluded (dev/process) files are listed so nothing load-bearing hides
  among them; an un-adopted `"./"` tool gets an *info* line that its install still ships
  the whole tree (never a WARN/FAIL — adoption is deliberate and per-tool, so the gate
  never regresses a tool's verdict before it opts in).

**Release-trigger model — by diff classification** (the Actions-quota-vs-freshness axis,
decided rather than left to judgment): any change that **affects the binary** (`cmd/`,
`internal/`, compiled packages, `go.mod`/`go.sum`, build flags/ldflags) goes through the
full release build (cross-compile → stamp → sign → `bin/` → `dist/bin/`) — the
minutes-expensive path, already `workflow_dispatch`-only. Changes that **don't** (skills,
manifests, README, CHANGELOG) are a cheap copy and sync to `dist/` continuously. This
keeps `dist/` binary freshness inheriting from `bin/` freshness (which the release build
guarantees) while avoiding a full cross-compile on every skill/README edit. The
skills-`go:embed` caveat is moot post-act-a3e279: the plugin reads `skills/<tool>/` from
the shipped files directly (the embed's only consumer, install-skill, was removed), so a
skill edit is not binary-affecting for plugin users.

> **Adoption is per-tool** (flip the marketplace `source` to `./dist`, un-gitignore +
> commit `dist/`, wire `stage-payload` into `release.yml`), and each adoption is proven
> by a live `/plugin install` on **both** Claude Code and Codex before it lands. Until a
> tool adopts, [check 16] runs in preview/info mode and changes nothing about its release.

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
- **The binary's *runtime* version has one source too.** Everywhere the binary
  reports its own version — the `version` subcommand AND the MCP `initialize`
  response's `serverInfo.version` — must read the single stamped source
  (`internal/version.Binary`, set by the release `-ldflags -X`). Never a second
  hardcoded literal: a `const serverVersion = "0.1.0"` in the MCP server passes
  the `version`-subcommand smoke yet drifts on every release (this shipped in ask
  0.2.0). [check 7] drives an initialize handshake against the staged binary and
  fails if `serverInfo.version` ≠ the release version.
- Claude auto-discovers `skills/` and `.mcp.json`, so `.claude-plugin/plugin.json`
  is minimal. Codex does not auto-discover, so `.codex-plugin/plugin.json` must
  carry explicit component pointers for whatever it bundles — `"skills":
  "./skills/"`, and `"mcpServers": "./.mcp.json"` when shipping MCP. Pointers
  start with `./`, stay inside the plugin root, and must resolve. The `interface`
  block is optional install-surface metadata — recommended for published plugins,
  not required for a valid manifest. [check 11]
- The skill description stays within Codex's 1024-char limit. [check 10]
- **The CHANGELOG carries the release notes.** Commit-to-main has no git tag or
  GitHub Release to hold a release body, so `CHANGELOG.md` is the only place it
  lives, and `bump-version` deliberately leaves authoring it to the human. [check
  15] guards that a release isn't cut with a blank changelog — it fails when a
  present `CHANGELOG.md` has no non-empty `## [Unreleased]` (or `## [<version>]`)
  section, and skips when a tool keeps no changelog. Draft the entry from the
  commit range with `bin/check-changelog --draft` (groups conventional commits by
  type since the last release commit); the guard and the draft are automated, the
  commit stays human. [check 15]

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
  dogfood logs, readiness notes — before shipping. They are how the work gets done,
  not the project a contributor consumes. An internal doc that carries no personal
  path or denylisted noun (design prose usually doesn't) slips past checks 8/9, so
  [check 14] surfaces every tracked `docs/*.md` outside a small allowlist
  (`docs/spec.md` by default; extend with `--docs-allow` or `$PLUGIN_KIT_DOCS_ALLOW`)
  as a candidate to untrack. WARN, not FAIL — the ship/untrack call stays human.
- `CLAUDE.md` is a thin pointer; build-side guidance ships as `AGENTS.md` (vendor
  -neutral — Codex and others read it; `CLAUDE.md` is Anthropic-specific); personal
  prefs/permissions stay in a gitignored `.claude/settings.local.json`. [check 12]
- **A tool that creates working-tree state gitignores it in its own init** — its
  dirs, lock files, generated artifacts, worktrees — so that state never leaks into
  a contributor's `git add -A`. Full principle: the agent-manual ("Tools own their
  gitignore footprint").

## No telemetry in a shipped tool

A tool you ship must not phone home. Never wire analytics, install-count beacons,
crash/error reporting, usage pings, or any "phone home" that emits usage data to an
external service into a released tool. This is a standing constraint, not a per-release
judgment — privacy and control, and a third-party send publishes the data (it may be
cached or indexed even if later deleted). The corollary matters most at ship time: when
a discovery, listing, or "get-discovered" path *depends* on emitting telemetry (a
registry that only indexes repos carrying an install ping, an install-count badge), the
path is **closed, not a tradeoff to weigh** — drop it, don't instrument for it. Mechanically
checkable later: a verifier scan for analytics/beacon patterns is plausible.

## Doc reconciliation — an opt-in advisory (check 17)

A release ships code, but the docs describing it drift silently: a README keeps
calling a now-shipped capability "planned", or a doc contradicts behaviour the
release changed. This is a judgement no deterministic rule can make, so [check 17]
is an **opt-in, advisory-only** step that asks a model whether the configured docs
still match what the release shipped.

- **Off by default.** It runs only when a reconcile command is configured, via
  `--reconcile-cmd <cmd>` or `$PLUGIN_KIT_RECONCILE_CMD` — a command that reads a
  prompt on stdin and prints a verdict on stdout. Unset ⇒ the check prints a skip
  notice and does nothing (graceful degrade — a bare CI runner or a public adopter
  who never opts in sees exactly the same skip as the no-denylist path in check 9).
  So it changes **zero** current verdicts until a tool opts in.
- **Advisory only — it never gates.** The verdict is surfaced on an `ADVISORY`
  line that counts as **neither a WARN nor a FAIL**. A nondeterministic model
  verdict must never be able to fail CI, so this holds **even under `--strict`**
  (where every WARN becomes a failure). The advisory informs the human; it never
  blocks the release.
- **Deterministic trigger — bounded cost.** The model is invoked **only** when the
  release delta actually contains user-facing (feature-ish) commits. The check
  reuses `check-changelog --draft`'s delta seam (the commit range since the last
  `release ...` commit) and treats its "no user-facing commits in range" sentinel
  as "nothing shipped worth reconciling" ⇒ skip, **no model call**. A docs-only or
  chore release costs nothing.
- **What it feeds the model.** The changelog delta (the `--draft` body plus the
  `CHANGELOG.md` `[Unreleased]` section) and the contents of the configured doc set
  (`--reconcile-docs` / `$PLUGIN_KIT_RECONCILE_DOCS`, default `README.md`), asking
  whether anything in the docs now contradicts what shipped or still describes as
  future/planned something that now exists.
- **Errors degrade, never fail.** If the reconcile command exits non-zero or emits
  no verdict, the check prints an `info` notice and moves on — a broken or missing
  model integration never fails a release.

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

1. **Verify (locally, optional pre-flight).**
   `PLUGIN_KIT_DENYLIST=<denylist-file> <kit>/bin/verify-release --repo .` — the
   prepare-release workflow runs this as a hard gate anyway, but running it first
   surfaces fixable FAILs (manifests, per-host MCP config, missing internal/version
   package) before you spend a CI run. Note: a tool that hasn't released yet has no
   committed binaries, so [check 7] FAILs until the first prepare-release run
   produces them — that's expected, not a blocker.

2. **Drift.** If check [7] **WARNs** that the pinned kit SHA is behind HEAD:
   review what changed — `git -C <kit> log <pinned>..HEAD` — and **bump
   deliberately** only if a change matters to this tool (edit the SHA in
   `.github/workflows/release.yml`, commit, re-verify). If it doesn't matter,
   leave it; the WARN is non-fatal. Never auto-bump without reading the diff —
   that re-introduces the supply-chain risk the SHA-pin prevents.

3. **Prepare the release (CI does everything).** Trigger the tool's `release.yml`
   (`workflow_dispatch`) with the target `version`. On a macOS runner it bumps the
   version across the manifests, builds + stamps + signs all arches via
   `stage-binaries`, runs `verify-release` as a gate (0 FAIL), and **commits the
   result to the default branch**. No tag, no GitHub Release, nothing built
   locally. Skill-only tools have no binaries to build but still bump + commit the
   version. (Add the `CHANGELOG.md` entry in a normal commit *before* dispatching —
   `bin/check-changelog --draft` drafts it from the commit range; the workflow's
   `verify-release` gate [check 15] fails the release if the changelog has no
   release notes, and the workflow never edits it.)

4. **Confirm the release landed.** The new commit is on the default branch with
   the bumped `version`; `/plugin install <tool>@<tool>` (Claude) and
   `codex plugin marketplace upgrade` + `codex plugin add` (Codex) pull it. Smoke
   it once on a real install per host (MCP server starts from the bundled binary).

   > **Codex upgrade gotcha.** `codex plugin marketplace upgrade <name>` re-clones
   > the marketplace's git source and frequently fails with a 30s clone timeout
   > (`fatal: early EOF`) on larger repos. This is a transient Codex-CLI network
   > flake, **not** a release failure — and it does not block the upgrade:
   > `codex plugin add <name>@<name>` resolves and installs the new version on its
   > own (verify with `codex plugin list`). Treat `plugin add` as the reliable
   > upgrade path; don't conclude the release is broken from an `upgrade` timeout.

5. **History check (before a first public release):**
   `<kit>/bin/check-history --repo .`. Clean (the normal case for a tool built
   verifier-green from commit one) → no repave; go to 6. Leaks (a legacy repo
   developed before the scrub discipline) → a **one-time privacy repave** is
   needed (squash from a clean snapshot; see *What's the maintainer's*) — surface
   it as an ask. The working-tree checks ([8]/[9]) stop new leaks at the source,
   so this is remediation for the past, not a standing step.

6. **HUMAN GATE — flip to public:** going public is a deliberate "ready for the
   world" call. The agent surfaces it as an ask; it does not change repo
   visibility itself (nor rewrite history when a repave is needed — both are
   destructive on a published repo).

For a still-private tool, steps 1–5 are the whole loop; the agent escalates the
human gate (6) as an ask and stops there. There is no separate "publish" step —
the commit-to-default-branch in step 3 already published; flipping the repo public
is what exposes it.
