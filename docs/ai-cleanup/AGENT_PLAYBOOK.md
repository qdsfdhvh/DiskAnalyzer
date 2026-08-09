# Cheap-Model Agent Playbook

Use this playbook when assigning one backlog task to a coding agent. The aim is to spend cheap-model tokens on bounded implementation and reserve stronger-model review for security and architecture gates.

## Configured Agents (2026-08)

Model assignments live in `~/.pi/agent/settings.json` → `subagents.agentOverrides` (no restart needed; `subagent get <name>` shows the live binding):

| Agent | Model | Role |
|---|---|---|
| `worker` | `deepseek/deepseek-v4-flash` | Cheap implementation — normal tasks |
| `scout` | `deepseek/deepseek-v4-flash` | Cheap codebase reconnaissance |
| `reviewer` | `openai-codex/gpt-5.6-sol` (`thinking: high`) | Strong-model review gates |

Dispatch implementation to `worker`; use `reviewer` for the T06/T09/T13/T15-style evidence reviews and any pre-release gate.

## Assignment Rule

One agent receives one task ID. It may modify only the files listed by that task plus a minimal compile fix directly caused by those changes. If another file is required, the agent stops and reports the required change instead of widening scope.

Every assignment includes these two references:

1. `docs/ai-cleanup/ARCHITECTURE.md`
2. the exact task section from `docs/ai-cleanup/IMPLEMENTATION_BACKLOG.md`

Do not give a cheap model the entire product request and ask it to choose the next work. The backlog already contains the decisions.

## Standard Prompt Template

```text
Implement task <TASK_ID> from docs/ai-cleanup/IMPLEMENTATION_BACKLOG.md.

Read first:
- CLAUDE.md
- docs/ai-cleanup/ARCHITECTURE.md
- only the <TASK_ID> section in docs/ai-cleanup/IMPLEMENTATION_BACKLOG.md
- every existing file listed under the task's Files section

Contract:
- Work only on <TASK_ID>; do not start dependent or deferred tasks.
- Preserve the architecture interfaces and invariants exactly.
- Modify only listed files unless a direct compile fix is necessary; report any extra file.
- Add the specified tests in the same change.
- Run the task acceptance commands.
- Do not alter BulkScan/DiskScanner unless the task explicitly lists them.
- Do not add dependencies, an Xcode project, shell-based deletion, permanent deletion, or unrelated refactors.

Return:
1. changed files;
2. behavior implemented;
3. commands run and exact result;
4. residual risks or blocked acceptance item;
5. `git diff --stat` summary.

Stop if the architecture and task conflict, if a required predecessor is absent, or after two distinct failed approaches. Report evidence instead of inventing a new design.
```

Replace `<TASK_ID>` and paste the task’s Goal/Files/Implementation/Tests/Acceptance into the prompt if the agent cannot reliably navigate Markdown headings.

## Before Starting a Task

The orchestrator checks:

- predecessor tasks are merged;
- working tree does not contain unrelated edits in task-owned files;
- `swift test` is green;
- task interfaces still match Architecture;
- no other agent owns the same production file.

A task begins only when all checks pass.

## Agent Completion Contract

A task is complete only when:

- all listed artifacts exist;
- all listed behavior is implemented;
- requested negative cases have tests;
- acceptance commands pass;
- no deferred behavior was added;
- no unexpected production file changed;
- the agent reports residual risk rather than claiming certainty.

Compilation without the task-specific tests is incomplete.

## Review Strategy

### Cheap mechanical review after every task

Use a second cheap model with this prompt:

```text
Review task <TASK_ID> only. Compare the diff against the exact task section and docs/ai-cleanup/ARCHITECTURE.md. Report:
- missing acceptance requirement;
- scope creep or unexpected file;
- untested branch;
- interface/invariant mismatch;
- build or test evidence missing.
Do not redesign the feature. Return findings ordered by severity with file:line.
```

The implementer fixes concrete findings and reruns acceptance once. Do not cycle cheap reviewers indefinitely.

### Strong-model gates

Use a stronger model only at these points:

1. **After T06:** verify domain seams, validator authority, and that drafts cannot smuggle executable fields.
2. **After T09:** security review of root containment, symlink handling, fingerprint checks, parent/child normalization, cancellation, partial failure, and TOCTOU residual risk.
3. **After T13:** verify state ownership and that Views contain no filesystem/network behavior.
4. **After T15:** privacy/security review of redaction, Keychain, logs, request schema, response validation, timeout, and fallback.
5. **Before release:** review the aggregate diff against the product contract, not code style alone.

These gates are evidence reviews. They do not authorize broad refactors unless a concrete defect requires one.

## Merge and Parallelization Plan

Recommended sequence:

```text
Lane A: T00 → T01 → T02 → T03 → T04 → T05 → T06 → T07
Lane B:                    T08 → T09
Lane C: T10 → T11 → T12 → T13  (starts after A+B contracts are merged)
Lane D: T14 → T15              (starts after T06/T07)
Finish: T16
```

Safe parallel work:

- T02 and T08 can run in parallel after T01, but T08 must consume the final `FileFingerprinting` seam from T03 before merge.
- T14 can run while UI tasks T10–T13 run.
- Documentation T16 runs after behavior stabilizes.

Unsafe parallel work:

- T10 and T12 both edit `AnalysisFlowViewModel.swift`.
- T11 and T12 both edit `CleanupPlanView.swift`.
- T11 and T13 may both touch scan-detail integration.
- Any two agents editing `Package.swift` or shared model files.

Prefer serial work unless wall-clock speed matters; merge conflict resolution by cheap models often costs more than the saved time.

## Context Budgeting

To reduce cheap-model drift:

- provide one task section, not the whole backlog;
- provide exact interfaces and invariants in the prompt;
- list allowed files explicitly;
- require one observable acceptance command;
- split any task estimated above roughly 300 production lines before assignment;
- ask the agent to read implementation files, not restate the entire repository;
- use fresh context for review instead of asking the implementer to self-certify.

## Failure Policy

The agent stops and reports a blocker when:

- a predecessor type/file is absent;
- Architecture contradicts compiling code;
- acceptance requires UI behavior unavailable in unit tests and the manual step cannot be run;
- two meaningfully different fixes fail;
- safe filesystem behavior is uncertain;
- work requires touching `BulkScan` or `DiskScanner` outside an explicitly listed task.

A blocker report contains the command/error, files inspected, two attempted paths, and smallest decision needed from the orchestrator.

## Per-Task Handoff Format

```markdown
## Task <ID> Handoff
- Status: complete | blocked
- Changed: `path`, `path`
- Tests: `command` → pass/fail summary
- Acceptance: each criterion with pass/fail
- Extra files: none | explanation
- Residual risks: concrete list
- Next dependency unblocked: <ID or none>
```

Store the handoff in the task/PR description rather than creating permanent repository files for every task.

## Release Evidence Checklist

- `swift test` passes.
- `swift build -c release` passes.
- `make app` produces an ad-hoc signed app.
- Scanner benchmark shows no material regression from the pre-feature baseline.
- No AI request includes raw home username, full URLs, fingerprints, or file content.
- An invalid AI response falls back to the local plan.
- A changed/replaced/symlinked candidate is skipped at preflight.
- High-risk items require explicit per-item approval.
- Partial Trash failures remain visible.
- Cancel stops the next cleanup item.
- Existing Files browser and Apps page still work.
