# aibox docs

## Active specs (the source of truth)

- [`module-spec.md`](module-spec.md) — **THE normative module contract** (`module.yaml` schema incl. `usage:` / `includes:` / `upgrade:`, hook contract, preflight checks, source pools, deploy conventions, residue cleanup, exit codes). **Read this before contributing a module.**

## Tooling (development + validation)

- [`../scripts/new-module.sh`](../scripts/new-module.sh) — scaffold a spec-compliant module skeleton (`checks:` + `usage:` + `includes:` included); the output passes the validator immediately.
- [`../scripts/validate-module.sh`](../scripts/validate-module.sh) — module conformance validator; the executable form of [`module-spec.md`](module-spec.md) §Onboarding, same rules CI enforces (`--all` for the whole repo).

## Design history (how we got here — not normative)

These are planning/design records for already-completed work; they're kept for traceability, not as current spec. If they conflict with the active spec above, the active spec wins.

- [`module-system-spec.md`](module-system-spec.md) — the original design draft that drove the `module.yaml` migration (`module.yaml` fields, port-conflict detection, dashboard TUI, shared base components). Superseded by [`module-spec.md`](module-spec.md); read only for design history.
- [`design/module-yaml-refactor-design.md`](design/module-yaml-refactor-design.md) — the design for the `registry.sh` → `module.yaml` migration + shared-component `base.env` propagation.
- [`design/windmill-module-plan.md`](design/windmill-module-plan.md) — the planning doc for the `windmill` module.

For the contributor guide (pitfalls, versioning, release flow), see [`../AGENTS.md`](../AGENTS.md).
