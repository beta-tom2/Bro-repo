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

## Free-only AI policy
- Do not add paid third-party AI APIs.
- Use deterministic tools before a model.
- Use Ollama only for low-risk read-only drafts, summaries and first-pass reviews.
- Treat all local-model output as untrusted.
- Require Codex review for architecture, security, authentication, database migrations, permissions, finance, production and release work.

## Verification
Never claim tests, builds, deployments or UI flows passed without observed evidence. Report commands actually run and their results.