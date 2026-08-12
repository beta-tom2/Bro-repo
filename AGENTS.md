# Albert DevCore Agent Rules

Albert DevCore is the shared development-control plane for current and future Albert projects. ADOS, Project Brain/repository context, AGENTS rules, and Albert Dev Skills are complementary layers, not competing frameworks.

## Operating model

1. Repository/project rules define product-specific truth and protected boundaries.
2. DevCore assembles bounded context, indexes, memory, routing, and deterministic-first support.
3. ADOS orchestrates checkpoints, handoffs, queues, verification ladders, scope guards, evidence gates, and resumability.
4. Albert Skill Router selects the smallest useful specialist skill set for the task.
5. Deterministic evidence and repository-native checks outrank narrative confidence from any model or skill.

## Skill routing

Before medium, complex, unfamiliar, risky, design, architecture, debugging, database, release, review, or discovery work, consult `skills/albert-skill-router/SKILL.md` and `skills/approved-skills.json`.

- Start with zero optional skills.
- Installed does not mean always invoked.
- Project rules and explicit user instructions win over skill guidance.
- New third-party skills are deny-by-default until audited.
- Do not let a skill expand scope, weaken safety, introduce paid external AI APIs, or bypass ADOS verification.
- Prefer Albert wrappers where they intentionally adapt third-party behavior to the autonomous workflow.

## Future-project inheritance

New repositories adopted through DevCore must receive the template `AGENTS.md`, preserve stronger repository-specific rules, and become eligible for Albert Skill Router without requiring the user to remember to activate it manually.

## Changes to DevCore

Keep Windows PowerShell 5.1 compatibility. Preserve the free-only AI policy and local-first trust boundary. Run the deterministic smoke tests when changing ADOS or DevCore behavior and do not claim verification without observed evidence.
