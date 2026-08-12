# ALBERT DEV SKILLS

ALBERT DEV SKILLS is the selective skill layer for Albert DevCore / ADOS.

## Goal

Make useful skills available by default across current and future development projects without forcing every skill into every task.

The system separates five concerns:

1. **Availability** — approved skills may be installed globally or per project.
2. **Routing** — `albert-skill-router` selects the smallest useful set for a task.
3. **Domain routing** — wrappers such as `albert-design-director` and `albert-architecture-review` coordinate overlapping expert skills.
4. **Project authority** — repository `AGENTS.md`, scoped rules, adapters, Project Brain, and explicit user instructions override skills.
5. **Evidence** — deterministic checks and ADOS Evidence Gate outrank narrative claims from any skill.

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

### Meta / routers
- `albert-skill-router`
- `albert-design-director`
- `albert-architecture-review`
- `find-skills`

### Design direction / polish
- `frontend-design` — primary concept/direction skill for meaningful new UI or substantial redesigns.
- `impeccable` — critique, audit, polish, hardening, responsive/adaptive cleanup, anti-pattern detection.
- `design-taste-frontend` — conditional experimental creative-variance skill; never the default design authority.

### Motion / design engineering
Routed selectively through `albert-design-director`:
- `emil-design-eng`
- `animate`
- `find-animation-opportunities`
- `improve-animations`
- `review-animations`
- `apple-design` (conditional)

### UI / mobile implementation
- `expo-native-ui`
- `expo-data-fetching`
- `expo-upgrade`
- `vercel-react-native-skills`

### Backend / data
- `supabase`
- `supabase-postgres-best-practices`

### Engineering quality
- `systematic-debugging`
- `verification-before-completion`
- `tdd`

### Architecture suite
Use only under `albert-architecture-review` for broad architecture work when needed:
- `improve-codebase-architecture`
- `codebase-design`
- `domain-modeling`
- `grilling` (interactive-only unless explicitly requested)

`ai-video-generation` from `skills-101/superpowers` remains intentionally unapproved.

## Design routing examples

### Tiny spacing/copy fix
No design skill if deterministic project checks are sufficient.

### New Expo screen
`albert-design-director` normally selects `frontend-design` + relevant Expo/RN specialist. `impeccable` may be used later for a final polish pass.

### Existing UI looks generic
`impeccable`; add experimental `design-taste-frontend` only when a creative reset or higher visual variance is actually wanted.

### Add purposeful motion to existing UI
`find-animation-opportunities` -> implement only selected opportunities -> `review-animations`.
If exact motion is already specified, use `animate` -> `review-animations`.

### Existing motion feels wrong
`improve-animations` -> selected implementation -> `review-animations`.

### Final UI shipping pass
`impeccable` + repository-native accessibility/responsive/performance checks + `verification-before-completion` when task risk warrants it.

## Other routing examples

### Unknown recurring bug
`systematic-debugging` + `verification-before-completion`; add `tdd` only if a durable regression test fits.

### Supabase query performance issue
`supabase-postgres-best-practices`; add `supabase` when platform semantics matter.

### Broad architecture review
`albert-architecture-review` coordinates the architecture suite. Do not trigger it for a local rename or tiny refactor.

## Install

Preview first:

```powershell
.\scripts\install-albert-dev-skills.ps1 -Global -DryRun
```

Install approved skills globally:

```powershell
.\scripts\install-albert-dev-skills.ps1 -Global
```

Install and copy Albert routers into a project:

```powershell
.\scripts\install-albert-dev-skills.ps1 -ProjectPath "C:\path\to\repo"
```

Global installation makes external skills available to compatible local agent environments. Project installation also places Albert routers under `.agents/skills/`.

## New project adoption

When DevCore adopts a new repository, the project inherits Skill Routing guidance from `template/AGENTS.md`. Meaningful UI/UX/frontend/motion work should route through `albert-design-director`; backend-only and tiny visual work should not pay design-skill overhead.

## ChatGPT / Work

OpenAI Skills can be automatically selected once installed in supported ChatGPT environments. Personal Skills availability depends on plan/workspace, and personal skills may require separate installation across product surfaces.

Therefore the Git repository is the canonical source of truth, while ChatGPT/Work installation remains an adapter step rather than assumed implicit state.

## Review loop

Use Skill Telemetry on real tasks. Periodically evaluate:
- did the selected skill improve correctness or visual quality?
- did it reduce exploration or rework?
- did it introduce unnecessary process or design churn?
- did it conflict with project rules or an established design system?
- did it inflate context without improving output?

Update the approved registry from repeated evidence, not popularity alone.
