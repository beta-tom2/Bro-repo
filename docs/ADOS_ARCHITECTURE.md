# Albert Development OS (ADOS)

ADOS is the zero-paid-API development operating layer for ATLAS, NAVIRA, and future repositories.

## Goals

- reduce repeated Codex context loading;
- route deterministic work before model work;
- use Ollama only for bounded read-only assistance;
- preserve repository-specific AGENTS.md and safety rules;
- create resumable task packets and handoffs;
- learn from Git history without external databases;
- remain compatible with Windows PowerShell 5.1.

## Architecture

```text
User task
  -> ADOS Dispatcher
  -> Change Detector
  -> DevCore Context Engine
  -> Repair Memory Search
  -> Heat Map
  -> Knowledge Graph
  -> Fix DNA
  -> Prompt Packet
  -> Codex or Local Read-Only Review
  -> Focused Checks
  -> Handoff
```

## Modules

### DevCore
Repository adoption, project registry, generated maps, task routing, context budgets, focused test plans, and prompt packets.

### Dispatcher
Classifies tasks into:
- CODEX_REQUIRED
- CODEX_PRIMARY_WITH_DETERMINISTIC_TOOLS
- LOCAL_FIRST_THEN_CODEX_VERIFY

### Change Detector
Uses Git status, staged and unstaged diffs, recent commits, and changed-file paths. It never scans the entire repository when the current change set is enough.

### Repair Memory
Indexes Git commit subjects and changed files into a local JSON file. Similarity is lexical and advisory. Source files and tests remain authoritative.

### Heat Map
Ranks project areas by change frequency and recency. It is a navigation hint, not a quality score.

### Knowledge Graph
Builds a lightweight graph from file imports and path relationships. It does not replace compiler or language-server dependency analysis.

### Fix DNA
Creates a compact signature for a task from terms, likely domains, changed files, route, and related historical repairs.

### Night Audit
Runs deterministic read-only checks for TODO markers, large source files, conflict markers, and repository health. It may optionally request a bounded local-model summary, but it never edits code.

### Handoff
Captures branch, commit, working tree, generated context, checks, task route, and continuation instructions.

## Storage

Generated local data is stored under:

```text
.ai/context/
.ai/memory/
.ai/analytics/
.ai/local-output/
```

Generated files should remain ignored by Git unless a repository explicitly decides otherwise.

## Trust model

1. Repository rules and source code are authoritative.
2. Deterministic tools are preferred over model guesses.
3. Local-model output is untrusted until verified.
4. Generated maps are navigation aids.
5. Security, authentication, permissions, migrations, production, releases, financial logic, and architectural decisions require Codex-level review and repository-specific authorization.

## No-paid-API boundary

ADOS does not require OpenAI API, Anthropic API, NVIDIA NIM, OpenRouter, hosted vector databases, paid embeddings, or hosted caches. The supported cloud reasoning path is the user's included ChatGPT/Codex subscription. Local assistance uses Ollama on the user's machine.
