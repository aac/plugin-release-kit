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
- `CLAUDE.md` is a thin pointer; build-side guidance ships as `AGENTS.md`; personal
  prefs/permissions stay in a gitignored `.claude/settings.local.json`.

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
