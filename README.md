# Albert DevCore

Бесплатное локальное ядро разработки для ATLAS, NAVIRA и будущих проектов.

## Принципы

- никаких платных AI API;
- Codex используется для сложной архитектуры, критического кода и финальной проверки;
- Ollama используется только для ограниченных read-only задач;
- сначала deterministic tools: Git, ripgrep, тесты, линтеры и статический анализ;
- контекст собирается инкрементально, без перечитывания всего репозитория;
- существующие AGENTS.md и проектные правила не перезаписываются.

## Команды

```powershell
.\devcore.ps1 doctor
.\devcore.ps1 adopt -ProjectPath "C:\path\to\repo"
.\devcore.ps1 update -ProjectPath "C:\path\to\repo"
.\devcore.ps1 route -Task "Исправить текст README"
.\devcore.ps1 local -ProjectPath "C:\path\to\repo" -Task "Проверь документацию" -Files @("README.md")
.\devcore.ps1 review -ProjectPath "C:\path\to\repo"
```

## v0.1

- диагностика окружения;
- безопасное подключение существующего репозитория;
- автоматическая карта репозитория;
- компактный session context;
- локальный task router;
- read-only Ollama runner;
- локальный reviewer текущего diff;
- журнал памяти решений и найденных проблем;
- шаблон для будущих проектов.

## Ограничения

DevCore не предоставляет локальной модели права изменять код. Любой её результат считается недоверенным до проверки исходниками, тестами и Codex.