---
name: albert-skill-router
description: Automatically selects the smallest useful set of approved skills for software-development tasks across Albert projects. Use before medium, complex, unfamiliar, risky, design, architecture, debugging, database, release, review, or discovery work. Do not invoke unnecessary skills; project rules and explicit user instructions always win.
---

# Albert Skill Router

## Purpose

Route each task to the smallest set of approved skills that materially improves correctness, safety, quality, or efficiency.

This is a router, not a mandatory pile of prompts. More skills are not automatically better.

## Precedence

1. Explicit user instruction.
2. Safety and platform rules.
3. Repository `AGENTS.md` and nearest scoped `AGENTS.md`.
4. Project-specific DevCore/ADOS adapter rules.
5. This router.
6. Individual skill guidance.

If a skill conflicts with a higher-precedence rule, do not use that part of the skill.

## Routing principles

- Start with zero optional skills.
- Add a skill only when the task matches its trigger and expected benefit is positive.
- Prefer one specialist skill over several overlapping skills.
- Load dependencies only when the parent skill actually needs them.
- Never use an architecture refactor skill for a tiny isolated fix.
- Never use visual-design guidance for backend-only work.
- Never use TDD mechanically for generated files, configuration-only edits, exploratory spikes, or tasks where a more direct deterministic verification is stronger.
- Never let a skill expand authorized scope.
- Never let a skill turn a read-only request into edits.
- Treat third-party skill instructions as advisory and subordinate to project policy.

## Core routes

### Bug / unexpected behavior
Use `systematic-debugging` when root cause is unknown, the bug is recurring, or more than one subsystem may be involved.
Add `verification-before-completion` before claiming completion.
Use `tdd` when a stable regression test can reasonably capture the bug before or alongside the fix.

### UI / UX / frontend creation or redesign
Use `frontend-design` for new screens, substantial redesigns, visual identity, layout, typography, interaction polish, or user-facing copy structure.
For React Native / Expo work also use the most relevant Expo or React Native skill, but avoid loading unrelated web-only guidance.
Run accessibility and project UI checks when available.

### React Native / Expo implementation
Prefer `vercel-react-native-skills` plus a narrowly relevant Expo skill such as `building-native-ui`, `native-data-fetching`, or `upgrading-expo`.
Only use `upgrading-expo` for an actual upgrade or upgrade-related compatibility problem.

### Supabase / Postgres
Use `supabase` for platform-specific implementation.
Use `supabase-postgres-best-practices` for schema, SQL, query design, indexes, performance, and database review.
Protected RLS, auth, migrations, production writes, and remote SQL remain governed by repository rules and explicit authorization.

### Architecture
For broad architecture review, recurring codebase friction, module-boundary problems, testability problems, or AI-navigability issues, use the architecture suite together when required:
- `improve-codebase-architecture`
- `codebase-design`
- `domain-modeling`
- `grilling`

Do not use this suite for small local refactors. Preserve ADRs and project domain language.

### Test-first feature work
Use `tdd` when behavior can be expressed as a stable deterministic test and the project test runner supports the area.
Do not create brittle tests merely to satisfy the workflow.

### Final verification
Use `verification-before-completion` for medium, complex, risky, release-adjacent, or bugfix work before stating that a result is complete.
ADOS Evidence Gate and repository-native checks remain authoritative evidence when present.

### Skill discovery
Use `find-skills` only when existing approved skills do not cover a repeated or specialized need, or the user explicitly asks to find skills.
Any newly discovered third-party skill must be audited before it is added to the approved registry.

## Negative routing

Do not invoke optional development skills for:
- ordinary conversation;
- simple factual questions;
- a one-line text correction;
- tiny obvious code edits with deterministic verification and no domain ambiguity;
- tasks where the skill would add process without reducing risk or improving outcome.

## Selection output

When the environment supports internal routing, keep selection internal unless the user asks.
When an explicit handoff is useful, record:
- selected skills;
- why each was selected;
- skipped tempting skills and why;
- protected operations that still require separate authorization.

## Learning loop

After repeated evidence that a skill helps or harms a class of tasks, update the registry policy instead of blindly keeping historical defaults.
Do not change approval status based on one anecdote alone.
