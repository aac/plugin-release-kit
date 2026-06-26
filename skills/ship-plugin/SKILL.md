---
name: ship-plugin
description: Use when shipping or releasing one of the agent-tools (ask, act, surface, reach, or a new sibling) as an installable plugin — cutting a release, running release-readiness checks, building or publishing the plugin zip, bumping the version, adopting a newer release kit, or deciding whether a repo is safe to go public. Fires on phrasings like "release ask", "ship this tool", "cut a vX.Y.Z", "is this ready to publish", "run the release checks", "make this a plugin". Drives the plugin-release-kit verifier and runbook, and knows the one-source version flow, the SHA-pin/drift discipline, and the human gates.
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

Any release-shaped intent on a tool repo: "ship/release this," "cut a tag," "is
this ready to publish," "run the checks," "adopt the latest kit." Works from the
tool repo or anywhere — it's directory-independent.

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

3. **Version.** Confirm `metadata.version` in `SKILL.md` is the intended release
   version (`bump-version <v> --repo .` to change everywhere; add the
   `CHANGELOG.md` entry). `check-versions --repo .` must be clean.

4. **Tag.** `git tag vX.Y.Z -m "…" && git push origin vX.Y.Z`. The release workflow
   builds the binary tarballs + the self-contained plugin zip and attaches both to
   a **draft** GitHub Release.

5. **Confirm artifacts** on the draft: 4 tarballs + `checksums.txt` +
   `<tool>-plugin.zip` (zip carries multi-arch binary + launcher + `skills/` +
   `.claude-plugin` + `.codex-plugin` + `.mcp.json`).

6. **History check (before a first public release):** `check-history --repo .`.
   Clean → no repave (the normal case for a tool built verifier-green from commit
   one). Leaks (a legacy repo) → a **one-time privacy repave** is needed — this is
   a **HUMAN** action; surface it as an ask and stop.

7. **HUMAN GATE — flip to public.** Going public is a deliberate call. Surface it
   as an ask; do not change repo visibility or rewrite history yourself.

8. **Publish:** flip GoReleaser `draft: true → false` once the first tagged run is
   validated end to end, then publish.

For a still-private tool, steps 1–6 are the whole loop; escalate the human gate
(7) as an ask and stop.

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
