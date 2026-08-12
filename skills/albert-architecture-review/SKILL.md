---
name: albert-architecture-review
description: Review broad codebase architecture using deep-module, domain-modeling, and codebase-friction principles without forcing interactive questioning. Use for recurring architectural friction, module-boundary problems, testability issues, or AI-navigability problems. Do not use for tiny local refactors.
---

# Albert Architecture Review

Use this as the Albert-safe wrapper around the approved Matt Pocock architecture suite.

## Inputs

Prefer:
- repository `AGENTS.md` and scoped rules;
- existing project glossary / Project Brain / CONTEXT.md when present;
- ADRs and prior decisions;
- recent Git hot spots and repeated change areas;
- relevant source and tests.

## Method

1. Scope before scanning. Focus on areas with actual friction or repeated change.
2. Apply `codebase-design` vocabulary and deep-module principles where useful.
3. Use `domain-modeling` only when terminology or domain boundaries genuinely need sharpening.
4. Use `improve-codebase-architecture` to surface a small set of meaningful deepening opportunities.
5. Treat the upstream `grilling` skill as optional interactive mode only. Do not block by default waiting for a questionnaire. If a decision is unresolved, state the decision tree, recommend a default, and continue with non-destructive analysis unless higher-precedence rules require user input.
6. Preserve existing ADRs and project-specific terminology.
7. Do not write architecture changes merely because an opportunity exists; implementation scope must come from the user's request.

## Output

For each meaningful candidate include:
- area / files;
- observed friction;
- why the current interface or seam is costly;
- recommended direction;
- expected leverage, locality, and testability benefit;
- migration risk;
- recommendation strength: Strong / Worth exploring / Speculative.

End with one top recommendation and a "do nothing" comparison so architecture work is justified rather than ceremonial.

## Guardrails

- No architecture astronautics.
- No speculative abstractions with only one hypothetical adapter.
- No broad refactor for a tiny bug.
- No rewriting project domain language to satisfy an external skill vocabulary.
- No protected production, auth, RLS, migration, financial, or release action without explicit authorization.
- Repository-native verification and ADOS evidence remain authoritative.
