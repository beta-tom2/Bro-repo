# ADR-0001: ADOS trust and evidence boundary

Status: accepted

## Context

ADOS reduces repeated context loading across ATLAS, NAVIRA, and future projects. Local automation must not trade lower model usage for weaker safety, unverifiable completion claims, or accidental changes to protected project configuration.

## Decision

- ADOS requires no paid third-party model, embedding, vector database, or cache API.
- Ollama is limited to bounded read-only assistance and cannot approve protected changes.
- Codex-level review remains required for architecture, security, authentication, permissions, database migrations, production, releases, financial logic, dependencies, and project-specific protected boundaries.
- Generated indexes, memories, checkpoints, queues, evidence, and analytics remain local under `.ai/` by default.
- Evidence Gate may return `VERIFIED` only after an observed diff or explicitly permitted analysis-only run, a passing Verification Ladder, a passing Scope Guard, and no detected secret pattern in added lines.
- Project adapters are advisory and do not rewrite ATLAS, NAVIRA, or future project configuration.

## Consequences

ADOS can reduce repeated scanning and noisy context while preserving a clear trust boundary. Some tasks remain `UNVERIFIED` until a human supplies authority or Codex completes protected reasoning. Deterministic byte and timing analytics are useful optimization proxies but are not presented as exact Codex token billing.

## Rejected approaches

- Hosted paid embeddings or model APIs for source indexing.
- Allowing a local model to edit product files or approve protected work.
- Treating generated memory, inferred adapters, or local-model output as authoritative evidence.
- Automatically executing queued work or scheduled product changes without explicit authorization.
