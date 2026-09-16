<!--
Thanks for the PR! Read CONTRIBUTING.md and AGENTS.md first.
Keep the title Conventional-Commits style: fix: / feat: / docs: / style: / chore:
-->

## What & why

<!-- What does this change do, and why? Link an issue if applicable. -->

## Changes

-
-

## Verification

- [ ] `bash -n` passes on all touched scripts
- [ ] `shellcheck --severity=error --shell=bash` passes (CI runs it)
- [ ] bash 3.2 gotcha scans clean (no full-width char right after a bare `$VAR`; no `local a=".." b="${a}/.."` same-line self-reference — AGENTS.md #1 #8)
- [ ] if a module changed, `module.yaml` still satisfies `module-lint` (required fields, §2.2 subset, ports format, lifecycle, dashboard)
- [ ] no new hardcoded credentials in composes (use `base.env` + `--env-file`)
- [ ] no new port conflicts across modules

## Notes for review

<!-- anything reviewers should watch for, e.g. a behavior change or a migration step -->
