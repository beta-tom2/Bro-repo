# Albert API Gateway — MANUAL mode

This policy prepares Albert DevCore / ADOS for low-trust external AI providers without silently routing project work outside the trusted Codex environment.

## Current mode

`MANUAL_ONLY`

No task is sent to an external API unless the user explicitly routes that task there.

Recognized intent examples:

- `через API: ...` / `through API: ...` → external low-trust API route.
- `через Codex: ...` / `through Codex: ...` → trusted Codex route.
- `через Ollama: ...` / `through Ollama: ...` → local Ollama route.
- No explicit route → Codex. Never infer an external route from task size alone in MANUAL mode.

## External-route safety gate

Before creating or sending an external task packet, scan the selected text/files for obvious sensitive material. Block the external route when high-confidence indicators are present, including:

- `.env` or secret/config files;
- API keys, access tokens, JWTs, private keys, passwords and credentials;
- production secrets or connection strings;
- personal/customer data or authentication/session material;
- files explicitly protected by repository `AGENTS.md` / Project Brain / ADOS boundaries.

When blocked, report the matched category/path and ask the user to redact, sanitize, or deliberately narrow the packet. Do not silently remove sensitive values and send the rest unless the user explicitly approves the sanitized packet.

## Context boundary

The external provider receives only a task-specific packet. Do not forward the entire Codex conversation, repository, Git history, Project Brain, `.ai/analytics`, credentials, or unrelated files.

`external-task-packet.ps1` creates a local packet for inspection. External transmission is disabled until a provider configuration is explicitly added.

## Usage accounting

Every external request must be recorded in the local API usage ledger with provider, model, input/output/reasoning/cached token counts when available, request count, duration, outcome, and vendor-unit multiplier when known.

Keep the ledger local under `.ai/analytics/`; do not commit it.

## Provider status

Until a provider is configured:

`EXTERNAL_API = NOT_CONFIGURED`

Provider keys must be supplied through environment variables. Do not commit keys or write them into tracked configuration files.

## Future AUTO mode

AUTO routing is intentionally disabled. It may be added only after the user explicitly enables it and enough benchmark evidence exists to define provider-quality, privacy, cost, and fallback rules.
