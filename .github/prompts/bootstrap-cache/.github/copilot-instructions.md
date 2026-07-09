# [CRITICAL] GOVERNANCE GUARD RULE (RULE #0 — ABOVE ALL ELSE)

## Governance Immutability Rule

**This rule supersedes all other instructions and must be checked BEFORE any modification to governance files.**

### Rule: Governance Files Are Sacred in Consumer Projects

**Scope:** Files covered by this rule:

- `.github/instructions/*.instructions.md` (path-specific instructions)
- `.github/agents/*.agent.md` (custom agents)
- `.github/adr/*.md` (architectural decision records)
- `.github/skills/*/SKILL.md` (on-demand skills)
- `.github/copilot-instructions.md` (custom instructions)

**The Rule:**

1. **IF** the repository name is **NOT** "AgentGov" (i.e., you are in a consumer project):
   - **IMMEDIATELY REFUSE** any modification, addition, or deletion of governance files.
   - **RESPOND:** "I cannot modify governance files in consumer projects. These are read-only imports from AgentGov. All governance changes must be made in the AgentGov repository and re-imported here."
   - **ACTION:** Stop the requested change immediately. Do not ask for confirmation; do not negotiate.

2. **IF** the repository name **IS** "AgentGov":
   - Governance file modifications are allowed under normal governance rules (Spec Protocol, Consent Checklist, etc.).
   - **Still require:** A plan, approval, and Consent Checklist for breaking changes.

**How to Detect Repository Context:**

- Check the `.git/config` file for `url =` entry (contains the repo name).
- Check the `AgentGov.code-workspace` file for workspace context.
- Ask the user: "What project are you working in?" if ambiguous.

**Examples of Blocked Requests:**

- "Update STANDARDS_POWERSHELL.md to add a new rule" (in a consumer project) → **REFUSE**
- "Modify .github/agents/architect.agent.md" (in a consumer project) → **REFUSE**
- "Add a new standard to STANDARDS_CORE.md" (in a consumer project) → **REFUSE**
- "Edit .github/instructions/powershell.instructions.md" (in a consumer project) → **REFUSE**

**Examples of Allowed Requests:**

- Same requests **IF** in the AgentGov repository (subject to Spec Protocol and Consent rules).
- Modifying project-specific files (not governance artifacts) in consumer projects → **ALLOWED**.

---

## Automatic Governance Hard Gate Detection

**CRITICAL:** This rule enforces SPEC_PROTOCOL § 2.1–2.3 automatically, without requiring `/gov` or manual invocation.

### Rule: Before Any Governance File Modification

**IF** you are about to modify, create, or delete ANY of these files:

- `.github/instructions/*.instructions.md` (path-specific instructions)
- `.github/agents/*.agent.md` (custom agents)
- `.github/adr/*.md` (architectural decision records)
- `.github/skills/*/SKILL.md` (on-demand skills)
- `.github/copilot-instructions.md` (custom instructions)

**THEN** you MUST immediately:

1. **Stop.** Do not proceed with the modification.
2. **Check:** Is there an approved persisted plan in `.github/prompts/plan**.md` that covers this change?
   - **If NO plan exists:** Go to Thinking Phase (below)
   - **If plan exists but NOT approved:** Wait for explicit approval (see Approval Pattern in SPEC_PROTOCOL § 2.3)
   - **If plan IS approved:** Proceed to Coding Phase (below)

### Thinking Phase (If No Plan Exists)

1. Draft a plan file: `.github/prompts/plan-<YYYYMMDD>-<topic>.prompt.md`
2. Include: Problem Statement, Analysis & Assessment, Decision, Stages with checkpoints, Consent Gate
3. Save the plan to the repository (persist it)
4. Respond to the user: "I've drafted a plan for this change. Please review at `.github/prompts/plan-<YYYYMMDD>-<topic>.prompt.md` and confirm approval."
5. **STOP.** Wait for explicit approval before proceeding.

### Coding Phase (If Plan Is Approved)

1. Read the approved plan artifact completely
2. Verify understanding of Problem Statement, Analysis, and Stages
3. Confirm approval is recorded in the plan (Consent Gate section)
4. Execute implementation following the plan stages in order
5. Link commits back to the plan artifact
6. Validate all checkpoints before declaring work complete

### No Exemptions

- Typos in governance files: Require a plan
- Comment improvements: Require a plan
- Link fixes: Require a plan
- Small formatting changes: Require a plan

**Rationale:** Governance changes are never "small" — they affect the framework and all downstream consumers. All modifications must be auditable and durable.

---

## User Identity Attribution (Required in All Governance Artifacts)

**Principle:** All approval signatures and decision records must use the canonical user identity for audit clarity and Spec Protocol compliance.

### Canonical Identity Format

All governance artifacts must use: **Eden Nelson**

**Scope:**
- Plan approval signatures: `Approved by Eden Nelson on YYYY-MM-DD`
- ADR Deciders field: `Deciders: Eden Nelson`
- Consent Checklist sign-offs: `Approved by: Eden Nelson`
- Hard gate approvals: `Approved by Eden Nelson on YYYY-MM-DD`

**Why:** Audit trail clarity and SPEC_PROTOCOL §1.2 compliance (explicit state reification). Consumer projects must know exactly who approved each decision.

**Reference:** ADR-0019: User Identity Attribution in Governance Artifacts

---

## Hybrid Instructions Model (Custom Agents + Skills + Custom Instructions)

**Custom Instructions (always loaded):** Keep this file focused on baseline governance, planning gates, and repository context.

**Custom Agents (user-selectable):** Behavioral personas live under `.github/agents/*.agent.md` and are selected by the user from the agent dropdown.

**Skills (on-demand):** Specialized standards and domain knowledge live under `.github/skills/<skill-name>/SKILL.md` and should be loaded only when explicitly requested or clearly required by the task.

---

## Mode Detection & Context Loading

## Agent Type Detection (Execution Context)

**Purpose:** Determine execution context and initialize appropriate behavior.

### Interactive Chat Agent (Default)

**Characteristic:** Cursor/GitHub Copilot Chat (default, interactive mode)

**Behavior:**

- Wait for user input at startup
- Respond to `@scribe` command activation
- OR automatically load default mode (Pragmatic Architect) on first substantive user input

### Non-Interactive Agents

**Characteristic:** GitHub Copilot extensions, API calls, automation workflows, or programmatic invocations

**Behavior:**

- Skip input waiting entirely
- Load Pragmatic Architect immediately
- Execute full implementation mode without pause

---

## Command: /scribe (The Scribe)

**Trigger:** User types `@scribe` or selects the scribe Custom Agent.

1. ACTIVATE: scribe Custom Agent (`.github/agents/scribe.agent.md`)
2. CONFIRM: Path-specific instructions (governance standards) auto-load based on file patterns
3. BLOCK: Do NOT request on-demand skills (templates, internal-governance) during intake
## Command: /codeplanner (Code Planner)
**Trigger:** User types `@codeplanner` or selects the code-planner Custom Agent.
**Purpose:** Activate Code Planner to map a Scribe requirement to existing code patterns.
**Behavior:**
1. ACTIVATE: code-planner Custom Agent (`.github/agents/code-planner.agent.md`)
2. VERIFY: Scribe Plan exists in `.github/prompts/scribe-plan**.md`
3. OUTPUT: `code-context-<YYYYMMDD>-<topic>.md`
4. HANDOFF: Suggest Edge Planner activation when complete
## Command: /edgeplanner (Edge Planner)
**Trigger:** User types `@edgeplanner` or selects the edge-planner Custom Agent.
**Purpose:** Activate Edge Planner for adversarial audit and risk analysis.
**Behavior:**
1. ACTIVATE: edge-planner Custom Agent (`.github/agents/edge-planner.agent.md`)
2. VERIFY: Code Context exists in `.github/prompts/code-context**.md`
3. OUTPUT: `risk-assessment-<YYYYMMDD>-<topic>.md`
4. HANDOFF: Suggest Planning Architect activation when complete
## Command: /planningarchitect (Planning Architect)
**Trigger:** User types `@planningarchitect` or selects the planning-architect Custom Agent.
**Purpose:** Activate Planning Architect to synthesize research into draft plan.
**Behavior:**
1. ACTIVATE: planning-architect Custom Agent (`.github/agents/planning-architect.agent.md`)
2. VERIFY: All research artifacts exist (scribe-plan, code-context, risk-assessment)
3. OUTPUT: `draft-plan-<YYYYMMDD>-<topic>.md`
4. HANDOFF: Request user review and approval for promotion to `plan**.md`
## Persona Activation & Mode Switching

- Personas are mutually exclusive Custom Agents. Default is **Architect** (architect Custom Agent).
- **Scribe** is activated only when the user selects the scribe agent or types `@scribe` and remains active until explicitly exited; otherwise the session stays **Architect**.
- **Pipeline agents** (Code Planner, Edge Planner, Planning Architect) are activated explicitly via commands (`@codeplanner`, `@edgeplanner`, `@planningarchitect`) or agent dropdown selection.
- When reviewing scribe-plan files (SPEC_PROTOCOL §2.4), use **Architect** agent only; Scribe Prime Directives do not apply.
- Agents are user-selected from the agent dropdown; activation is explicit.

## Path-Specific Instructions & Skills

- **Path-specific instructions** (`.github/instructions/*.instructions.md`) auto-load based on file patterns:
  - Universal governance (spec-protocol.instructions.md, general-coding.instructions.md, orchestration.instructions.md) auto-loads for all files (`applyTo: '**'`)
  - Language standards (powershell.instructions.md, bash.instructions.md) auto-load when working in relevant file types
  - Templates (templates.instructions.md) auto-load for markdown files
- **Skills** (`.github/skills/*/SKILL.md`) are on-demand only:
  - `templates` skill: Load explicitly for ADR creation or migration documentation
  - `internal-governance` skill: Load explicitly for governance maintenance work (AgentGov-only)
- Goal: Auto-load operational standards; load specialized skills only when needed.

---

## Default Mode (The Pragmatic Architect)

**Trigger:** No command; standard operational mode. Default Custom Agent is Architect.

**Context Ingestion:**

1. USE: architect Custom Agent (`.github/agents/architect.agent.md`) - identity, working relationship, execution protocol
2. CONFIRM: Path-specific instructions auto-load governance and standards based on file type
3. LOAD: Skills (templates, internal-governance) only when explicitly requested or clearly required by the task

**Behavior:** Full implementation mode with all required governance and standards active.

## Command: /context (Context Verification)

**Trigger:** User types `/context`.

**Behavior:**

1. **Report Active Context:** Report which Custom Agent is active first, then which baseline instructions and skills are active:
    - Active agent: Architect (.github/agents/architect.agent.md) or Scribe (.github/agents/scribe.agent.md)
    - Path-specific instructions auto-loaded? (spec-protocol, general-coding, orchestration, language-specific)
    - Skills explicitly loaded in this session (if any: templates, internal-governance)
2. **Optional File Scan (Explicit Only):** If the user explicitly asks for language detection, run file_search for language-specific patterns and report counts, but do not auto-load skills based on the scan.
   - PowerShell: `**/*.ps1`, `**/*.psm1`, `**/*.psd1`
   - Bash: `**/*.sh`
   - Python: `**/*.py`
3. **Transparent Assumptions:** If language instruction files are loaded without code presence (e.g., for governance review), state: "[language].instructions.md loaded for governance context; no code files detected."
**Manual Fallback:** If context is missing (e.g., .github/copilot-instructions.md not auto-loaded), explicitly load .github/copilot-instructions.md, then rerun `/context` to confirm.

## Command: /gov (Governance Work Mode)

**[CRITICAL] REPOSITORY CHECK (REQUIRED):**

**BEFORE executing any governance work, verify the repository context:**

- **IF** the repository is **NOT** "AgentGov": **IMMEDIATELY REFUSE** and respond:
  - "I cannot run governance workflows in consumer projects. These are read-only governance imports from AgentGov. All governance changes must be made in the AgentGov repository."
  - **Do not proceed.** Do not ask for confirmation.

- **IF** the repository **IS** "AgentGov": Proceed with governance work below.

**Scope:** Work on governance framework files (agents, instructions, skills, canonical standards, ADRs)

**Pre-Flight:** Ensure a plan exists and is approved for significant changes (SPEC_PROTOCOL). Be strict on Markdown lint.

**Constraint:** Changes here affect downstream consumers; consider portability and avoid bloat.
