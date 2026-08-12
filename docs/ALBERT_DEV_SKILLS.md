# ALBERT DEV SKILLS

ALBERT DEV SKILLS is the selective skill layer for Albert DevCore / ADOS.

## Goal

Make useful skills available by default across current and future development projects without forcing every skill into every task.

The system separates four concerns:

1. **Availability** — approved skills may be installed globally or per project.
2. **Routing** — `albert-skill-router` selects the smallest useful set for a task.
3. **Project authority** — repository `AGENTS.md`, scoped rules, adapters, and explicit user instructions override skills.
4. **Evidence** — deterministic checks and ADOS Evidence Gate outrank narrative claims from any skill.

## Default policy

- Installed does not mean invoked.
- Optional skill count should normally stay small.
- Third-party skills are deny-by-default until audited.
- A skill may not expand authorized scope.
- A skill may not turn a read-only task into edits.
- Protected operations remain protected regardless of skill instructions.
- Skills that repeatedly add noise or reduce quality should be demoted or disabled by route, not kept from habit.

Approved status is recorded in `skills/approved-skills.json`.

## Approved pack

### Meta
- `albert-skill-router`
- `find-skills`

### UI / mobile
- `frontend-design`
- `building-native-ui`
- `native-data-fetching`
- `upgrading-expo`
- `vercel-react-native-skills`

### Backend / data
- `supabase`
- `supabase-postgres-best-practices`

### Engineering quality
- `systematic-debugging`
- `verification-before-completion`
- `tdd`

### Architecture suite
Use together only for broad architecture work when needed:
- `improve-codebase-architecture`
- `codebase-design`
- `domain-modeling`
- `grilling`

`ai-video-generation` from `skills-101/superpowers` is intentionally not approved at this time.

## Routing examples

### Small copy fix
No optional skill.

### Unknown recurring bug
`systematic-debugging` + `verification-before-completion`; add `tdd` only if a durable regression test fits.

### New Expo screen
`frontend-design` + relevant React Native/Expo specialist; verification after implementation.

### Supabase query performance issue
`supabase-postgres-best-practices`; add `supabase` when platform semantics matter.

### Broad architecture review
Architecture suite. Do not trigger it for a local rename or tiny refactor.

## Install

Preview first:

```powershell
.\scripts\install-albert-dev-skills.ps1 -Global -DryRun
```

Install approved third-party skills globally:

```powershell
.\scripts\install-albert-dev-skills.ps1 -Global
```

Install and copy the Albert router into a project:

```powershell
.\scripts\install-albert-dev-skills.ps1 -ProjectPath "C:\path\to\repo"
```

Global installation makes external skills available to compatible local agent environments. Project installation also places the Albert router under `.agents/skills/albert-skill-router`.

## New project adoption

When DevCore adopts a new repository, the project should inherit the Skill Routing section from `template/AGENTS.md`. The project can keep stricter local rules.

A future improvement should make `devcore.ps1 adopt` optionally copy the router automatically after a deterministic compatibility check.

## ChatGPT / Work

OpenAI Skills can be automatically selected once installed in supported ChatGPT environments. Personal Skills availability depends on plan/workspace, and personal skills currently require separate installation on desktop and web/mobile surfaces rather than automatic cross-surface synchronization.

Therefore the Git repository is the canonical source of truth, while ChatGPT/Work installation is an adapter step rather than assumed implicit state.

## Review loop

Periodically evaluate each skill on real tasks:
- did it improve correctness?
- did it reduce exploration or rework?
- did it introduce unnecessary process?
- did it conflict with project rules?
- did it inflate context without improving output?

Update the approved registry from repeated evidence, not popularity alone.
