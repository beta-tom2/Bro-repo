# Albert DevCore and ADOS

Free local development infrastructure for ATLAS, NAVIRA, and future projects.

## Principles

- no paid AI APIs;
- Codex is used for architecture, critical code, and final verification;
- Ollama is limited to bounded read-only tasks;
- deterministic tools run before model work;
- context is assembled incrementally instead of rereading the repository;
- existing AGENTS.md and repository-specific rules remain authoritative;
- generated memory and analytics remain local by default;
- Windows PowerShell 5.1 compatibility is required.

## DevCore commands

```powershell
.\devcore.ps1 doctor
.\devcore.ps1 adopt -ProjectPath "C:\path\to\repo"
.\devcore.ps1 register -ProjectPath "C:\path\to\repo"
.\devcore.ps1 projects
.\devcore.ps1 update -ProjectPath "C:\path\to\repo"
.\devcore.ps1 route -Task "Review README wording"
.\devcore.ps1 packet -ProjectPath "C:\path\to\repo" -Task "Fix a friends bug"
.\devcore.ps1 local -ProjectPath "C:\path\to\repo" -Task "Review documentation" -Files @("README.md")
.\devcore.ps1 review -ProjectPath "C:\path\to\repo"
```

## ADOS commands

ADOS orchestrates DevCore, repair memory, Heat Map, Knowledge Graph, Fix DNA, prompt packets, audits, and handoffs.

```powershell
.\ados.ps1 doctor

.\ados.ps1 start `
  -ProjectPath "C:\path\to\repo" `
  -Task "Fix the error when adding a found user as a friend"

.\ados.ps1 analyze `
  -ProjectPath "C:\path\to\repo" `
  -Task "Prepare the next safe project stage"

.\ados.ps1 night `
  -ProjectPath "C:\path\to\repo"

.\ados.ps1 handoff `
  -ProjectPath "C:\path\to\repo"
```

## ADOS modules

- Dispatcher: selects Codex, deterministic-first, or local-first execution.
- Change Detector: reads current Git state before broad repository context.
- Context Engine: generates maps, focused checks, and task packets.
- Repair Memory: indexes commit subjects and changed paths locally.
- Heat Map: ranks frequently and recently changed areas.
- Knowledge Graph: creates a lightweight import relationship graph.
- Fix DNA: records task terms, route, domains, and changed files.
- Night Audit: reports conflict markers, large files, TODOs, and repository status without editing code.
- Handoff: creates a resumable continuation packet.

Architecture details are in `docs/ADOS_ARCHITECTURE.md`.

## Generated local files

ADOS may create files under:

```text
.ai/context/
.ai/memory/
.ai/analytics/
.ai/local-output/
```

The orchestrator adds them to `.git/info/exclude` so they remain local even when a project does not yet contain shared ignore rules.

## Trust boundary

DevCore and ADOS do not give local models permission to modify product code. Local-model output, generated dependency maps, historical similarity, Heat Map scores, and audit findings are advisory until verified against source code, deterministic checks, and Codex review.

Security, authentication, permissions, RLS, migrations, production, releases, financial logic, dependencies, and architecture remain protected domains.
