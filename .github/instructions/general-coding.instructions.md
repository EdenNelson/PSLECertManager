---
name: 'General Coding'
description: 'Core coding standards, principles, quality assurance, and API orchestration'
applyTo: '**'
---
# AI CODING STANDARDS: CORE & ORCHESTRATION

**AUTHORITY:** These rules are the primary constraints for all automation, code generation, and edits in this repository.

**SCOPE:** General Orchestration logic, API interactions, and Global behaviors.

**INHERITANCE:** Respect existing project standards in PROJECT_CONTEXT.md and Powershell.instructions.md.

**CONSENT:** For any breaking or major change impacting end-user usage, follow the mandatory Consent Gate in orchestration.instructions.md and the Spec Protocol in spec-protocol.instructions.md before proceeding.

## 1. GENERAL PRINCIPLES

### 1.1 Core Values

- **Priorities:** Correctness, Clarity, and Idempotence > Brevity.
- **Spec Protocol Requirement:** Significant architectural changes must be written, persisted, and approved before implementation (see spec-protocol.instructions.md).
- **Idempotency:** All scripts must be re-runnable without side effects (Check → Test → Set pattern).

### 1.2 AI Interaction & Context

- **Conciseness:** Keep outputs concise. Do not re-quote large prior sections; link or summarize instead to save context window.
- **Enforcement:** If rules cannot be satisfied due to missing context, pause and request details.

### 1.3 File Boundaries (Governance Location)

- Do not place governance rules in PROJECT_CONTEXT.md. That file is project-specific context only.
- Canonical governance lives in: .github/agents/*.agent.md, .github/instructions/*.instructions.md, .github/skills/*/SKILL.md, .github/copilot-instructions.md, ADRs.
- PROJECT_CONTEXT.md may link to governance files but must not define rules or workflows.

**NOTE:** Markdown formatting standards are defined in markdown.instructions.md (auto-loads for all *.md files).

## 2. API & ENDPOINT ORCHESTRATION

### 2.1 "Check Before Act"

Never assume system state. Verify connectivity and file existence before operations.

### 2.2 Resiliency

- **Retries:** Implement exponential backoff for all HTTP requests.
- **Validation:** Check HTTP Status Codes strictly. Validate JSON payloads before parsing.

### 2.3 Authentication

- **Secrets:** Never hardcode. Expect secrets via Environment Variables or Key Vaults.
- **Headers:** Construct headers in a dedicated object at the start of the script.

## 3. QUALITY ASSURANCE (REFLEXION PROTOCOL)

### 3.1 The Silent Review

Before outputting any code or artifact, you must perform an internal "Reflexion Loop":

1. **Draft:** Generate the solution internally.
2. **Critique:** Compare the draft against:
   - The active `SPEC_PROTOCOL` Plan (if applicable).
   - `STANDARDS_CORE` (Idempotency, Error Handling).
   - Language Specific Standards (Syntax, Safety).
3. **Fix:** Correct any violations *before* outputting.

### 3.2 The Reflexion Tag

If you catch and correct a violation during the Silent Review, you may append a brief footer to your response:
> **Reflexion:** I initially used `Write-Host` but self-corrected to `Write-Verbose` to align with Standards §2.1.
