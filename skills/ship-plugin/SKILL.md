---
name: ship-plugin
description: Use when shipping or releasing one of the agent-tools (ask, act, surface, reach, or a new sibling) as an installable plugin — cutting a release, running release-readiness checks, triggering the prepare-release workflow, bumping the version, adopting a newer release kit, or deciding whether a repo is safe to go public. Fires on phrasings like "release ask", "ship this tool", "cut a release", "is this ready to publish", "run the release checks", "make this a plugin". Drives the plugin-release-kit verifier and runbook, and knows the commit-to-main release model, the one-source version flow, the SHA-pin/drift discipline, and the human gates.
---

# ship-plugin — releasing an agent-tool as a plugin

This skill is the **invocation surface** for `plugin-release-kit` — the canonical
mechanism + playbook for shipping the agent-tools as plugins. The kit is the
single source of truth; this skill tells you when and how to drive it. Run the
whole loop yourself (agent-run end to end); escalate to the human only at the
gates marked **HUMAN**.

The kit's commands are on `PATH` (via `bin/install`): `verify-release`,
`check-versions`, `bump-version`, `check-history`, `gen-codex-marketplace`. The
canonical detail lives in the kit's `playbook/release-playbook.md` — read it for
anything this skill leaves implicit; it defers to the playbook.

## When this fires

Any release-shaped intent on a tool repo: "ship/release this," "cut a release,"
"is this ready to publish," "run the checks," "adopt the latest kit." Works from
the tool repo or anywhere — it's directory-independent.

## The release runbook (drive this end to end)

Run from the tool repo, with a `git pull`-current kit checkout.

1. **Verify.** `verify-release --repo .` (the denylist auto-resolves from
   `~/.config/plugin-release-kit/denylist` — no path to pass). Any **FAIL** is a
   release-readiness violation; the message names the rule. Fix and re-run until
   `0 FAIL`.

2. **Drift.** If check [7] **WARNs** that the pinned kit SHA is behind kit HEAD,
   review the change (`git log <pinned>..HEAD` in your plugin-release-kit
   checkout) and bump the SHA in `.github/workflows/release.yml` **only if it
   matters** to this tool. Never bump blindly: that re-introduces the
   supply-chain risk the immutable pin prevents. The WARN is non-fatal.

3. **Prepare the release (CI does it all).** Trigger the tool's `release.yml`
   (`workflow_dispatch`) with the target `version`. On a macOS runner the kit's
   reusable workflow bumps the version across the manifests, builds + version-
   stamps + ad-hoc-signs all arches into `bin/`, gates on `verify-release`, and
   **commits the result to the default branch**. No tags, no GitHub Releases, no
   tarballs, nothing built locally. (Add the `CHANGELOG.md` entry in a normal
   commit — the workflow doesn't touch it.)

4. **Confirm it landed.** The new commit is on the default branch with the bumped
   `version`. `/plugin install <tool>@<tool>` (Claude) and `codex plugin
   marketplace upgrade` + `codex plugin add` (Codex) pull it; smoke the MCP server
   once per host on a real install.

5. **History check (before a first public release):** `check-history --repo .`.
   Clean → no repave (the normal case for a tool built verifier-green from commit
   one). Leaks (a legacy repo) → a **one-time privacy repave** is needed — this is
   a **HUMAN** action; surface it as an ask and stop.

6. **HUMAN GATE — flip to public.** Going public is a deliberate call. Surface it
   as an ask; do not change repo visibility or rewrite history yourself. There is
   no separate publish step — the commit in step 3 already released; flipping the
   repo public is what exposes it.

For a still-private tool, steps 1–5 are the whole loop; escalate the human gate
(6) as an ask and stop.

## Discipline (the load-bearing bits)

- **One version source:** `SKILL.md` `metadata.version`; everything else matches it
  via `check-versions`. The Codex marketplace is version-less.
- **SHA-pin the reusable workflow** (it runs with `contents: write`); adopt kit
  updates by bumping the pin *deliberately* after reading the diff. The drift WARN
  surfaces staleness — it does not auto-fix.
- **Privacy:** leaks are caught by `verify-release` [8]/[9] (working tree) and
  `check-history` (full history); the *first* line is keeping shippable content
  generic while authoring (no personal names/paths/private command names).
- **Human gates are only:** the privacy repave (only if `check-history` flags it)
  and the flip-to-public. Everything else the agent does.

When in doubt on any rule, read the kit's `playbook/release-playbook.md` — it is
canonical and this skill defers to it.
