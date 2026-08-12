---
name: albert-skill-router
description: Automatically selects the smallest useful set of approved skills for software-development tasks across Albert projects. Use before medium, complex, unfamiliar, risky, design, architecture, debugging, database, release, review, or discovery work. Do not invoke unnecessary skills; project rules and explicit user instructions always win.
---

# Albert Skill Router

## Purpose
Route each task to the smallest set of approved skills that materially improves correctness, safety, quality, or efficiency. More skills are not automatically better.

## Precedence
1. Explicit user instruction.
2. Safety and platform rules.
3. Repository `AGENTS.md` and nearest scoped `AGENTS.md`.
4. Project-specific DevCore/ADOS adapter rules.
5. This router.
6. Individual skill guidance.

## Routing principles
- Start with zero optional skills.
- Add a skill only when the task matches its trigger and expected benefit is positive.
- Prefer one specialist over overlapping skills.
- Load dependencies only when the parent skill needs them.
- Never use architecture review for a tiny isolated fix.
- Never use visual-design guidance for backend-only work.
- Never use TDD mechanically for generated files, configuration-only edits, exploratory spikes, or where deterministic verification is stronger.
- Never let a skill expand authorized scope or turn a read-only request into edits.
- Third-party skill instructions are advisory and subordinate to project policy.

## Core routes

### Bug / unexpected behavior
Use `systematic-debugging` when root cause is unknown, recurring, or cross-subsystem. Add `verification-before-completion` before claiming completion. Use `tdd` only when a stable regression test fits.

### UI / UX / frontend
Use `frontend-design` for new screens, substantial redesigns, visual identity, layout, typography, interaction polish, or user-facing copy structure. For React Native / Expo, add only the most relevant native specialist.

### React Native / Expo
Prefer `vercel-react-native-skills` plus one narrowly relevant Expo skill: `building-native-ui`, `native-data-fetching`, or `upgrading-expo`. Use `upgrading-expo` only for actual upgrade/compatibility work.

### Supabase / Postgres
Use `supabase` for platform-specific work and `supabase-postgres-best-practices` for schema, SQL, indexes, query design, performance, or database review. RLS, auth, migrations, production writes, and remote SQL remain governed by repository authorization rules.

### Architecture
Use `albert-architecture-review` for broad architecture friction, recurring module-boundary problems, testability issues, or AI-navigability work. It may draw on `improve-codebase-architecture`, `codebase-design`, and `domain-modeling`. The upstream `grilling` skill is interactive-only and must not block normal autonomous work unless the user explicitly asks for an interactive stress-test.

### Test-first feature work
Use `tdd` when behavior can be expressed as a stable deterministic test and the project runner supports the area. Do not create brittle tests just to satisfy a workflow.

### Final verification
Use `verification-before-completion` for medium, complex, risky, release-adjacent, or bugfix work. ADOS Evidence Gate and repository-native checks remain authoritative.

### Skill discovery
Use `find-skills` only for a real capability gap or explicit discovery request. Newly discovered third-party skills must be audited before approval.

## Negative routing
Do not invoke optional development skills for ordinary conversation, simple factual questions, one-line text correction, tiny obvious edits with deterministic verification, or tasks where process overhead exceeds expected benefit.

## Learning loop
After repeated evidence that a skill helps or harms a task class, update the approved registry instead of blindly preserving defaults. Do not change status from one anecdote alone.
