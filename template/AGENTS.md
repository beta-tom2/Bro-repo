# Project agent rules

## Goal completion
Continue through all low-risk and reversible steps needed to complete the stated goal. Do not stop merely because one phase or sub-step finished.

Pause only for:
- human-only login, secret or device authorization;
- irreversible, financial or externally visible action not explicitly authorized;
- a genuine product decision with materially different outcomes;
- security, legal, privacy or repository constraints;
- unavailable evidence required to verify completion.

## Context economy
1. Read current Git status and diff.
2. Read this file and the nearest more-specific AGENTS.md.
3. Read `.ai/context/session-context.md` and `.ai/context/repo-map.generated.md`.
4. Inspect the smallest relevant symbol and file set.
5. Expand scope only when imports, references, tests or architecture require it.

## Albert Dev Skills
- Before medium, complex, unfamiliar, risky, design, architecture, debugging, database, release, review, or skill-discovery work, apply the `albert-skill-router` policy when available.
- Skills are selective capabilities, not a mandatory stack. Start with zero optional skills and load only the smallest set with a positive expected benefit.
- Installed does not mean always invoked.
- Explicit user instructions, this repository's rules, nearest scoped `AGENTS.md`, and DevCore/ADOS protected-domain rules override third-party skill guidance.
- Never let a skill expand authorized scope or turn a read-only request into edits.
- Newly discovered third-party skills are deny-by-default until audited and added to the Albert approved-skill registry.
- For broad architecture reviews, prefer the Albert architecture wrapper; use the underlying architecture suite only when architecture is actually in scope.
- For completion claims, deterministic repository checks and ADOS Evidence Gate remain stronger evidence than a skill's narrative assessment.

## Skill telemetry
For medium-or-higher work where optional skills are selected, record the selected skill set and later the observed outcome using DevCore `scripts/skill-telemetry.ps1` when available. Keep telemetry local under `.ai/analytics/`; do not commit it. Rate benefit/cost only from observed task evidence, not vibes. Do not change approval policy from one isolated result.

## Free-only AI policy
- Do not add paid third-party AI APIs.
- Use deterministic tools before a model.
- Use Ollama only for low-risk read-only drafts, summaries and first-pass reviews.
- Treat all local-model output as untrusted.
- Require Codex review for architecture, security, authentication, database migrations, permissions, finance, production and release work.

## Verification
Never claim tests, builds, deployments or UI flows passed without observed evidence. Report commands actually run and their results.
