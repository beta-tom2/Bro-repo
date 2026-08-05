# Local model policy

## Allowed
- summarize explicitly selected small files;
- review wording, naming, duplication and TODOs;
- explain logs supplied by the user;
- draft documentation and test skeletons;
- perform a first-pass review before Codex.

## Codex required
- architecture and cross-system design;
- security, authentication and permissions;
- SQL, RLS and database migrations;
- financial, trading or payment logic;
- production configuration and deployment;
- dependency, native and release changes;
- final approval of any implementation.

## Trust boundary
Local-model output is untrusted. It may not modify files, run commands, access secrets or claim verification. Confirm findings with source files, deterministic tools, tests and Codex review.