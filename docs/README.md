# aibox docs

## Active specs (the source of truth)

- [`module-spec.md`](module-spec.md) — the module hook contract (how to build a module: `module.yaml` + `install/uninstall/update/svc.sh` + the deploy/config conventions). **Read this before contributing a module.**
- [`module-system-spec.md`](module-system-spec.md) — the module-system reference (`module.yaml` fields, port-conflict detection, dashboard TUI, shared base components, exit codes, interactive confirmation).

## Tooling (development + validation)

- [`../scripts/new-module.sh`](../scripts/new-module.sh) — scaffold a spec-compliant module skeleton (`checks:` included); the output passes the validator immediately.
- [`../scripts/validate-module.sh`](../scripts/validate-module.sh) — module conformance validator; the executable form of [`module-spec.md`](module-spec.md) §Onboarding, same rules CI enforces (`--all` for the whole repo).

## Design history (how we got here — not normative)

These are planning/design records for already-completed work; they're kept for traceability, not as current spec. If they conflict with the active specs above, the active specs win.

- [`design/module-yaml-refactor-design.md`](design/module-yaml-refactor-design.md) — the design for the `registry.sh` → `module.yaml` migration + shared-component `base.env` propagation.
- [`design/windmill-module-plan.md`](design/windmill-module-plan.md) — the planning doc for the `windmill` module.

For the contributor guide (pitfalls, versioning, release flow), see [`../AGENTS.md`](../AGENTS.md).
