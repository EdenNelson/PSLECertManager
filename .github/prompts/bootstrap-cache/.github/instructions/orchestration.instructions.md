---
name: 'Orchestration & Consent Standards'
description: 'Change management, user consent, Spec Protocol, verification, and ADR workflow'
applyTo: '**'
---
# AI CODING STANDARDS: ORCHESTRATION & CONSENT

**AUTHORITY:** These rules are binding for all automated edits and refactors performed by the agent in this repository.

**SCOPE:** Orchestration behaviors that can affect end-user interaction, interfaces, and workflows.

**INHERITANCE:** These rules extend and do not weaken the guidance in general-coding.instructions.md and PROJECT_CONTEXT.md.

## 1. Change Management & User Consent

### 1.1 Consent Gate (Mandatory)

Before implementing any breaking change or major change that affects how end users interact with the project, the agent must pause and obtain explicit user approval. This applies in all modes, including Agent/Autonomous mode and when the user asks to "refactor" or make broad changes.

- **Scope:** CLI/API contracts, defaults, env vars, config keys/paths, file formats/layout, schemas, migrations, removals/renames — any change affecting backward compatibility or user workflows.
- **Non-bypassable:** Requires explicit approval; cannot be skipped by prompt phrasing.
- **Safe default:** When uncertain, treat as breaking and request consent.

### 1.2 Required Approval Flow

1. **Propose:** Summary, affected surfaces, compatibility impact, risks, rollback/alternatives.
2. **Ask:** "Proceed with this breaking/major change?" Wait for explicit confirmation.
3. **Record Approval:** Signature must use canonical identity: `Approved by Eden Nelson on YYYY-MM-DD` (Example: `Approved by Eden Nelson on 2026-02-18`)
4. **Implement:** After approval only; focused changeset with migration guidance.

### 1.3 Migration & Documentation

- Provide MIGRATION note with required user actions (renames, flags, defaults, conversions).
- Update docs/examples; use `feat!:`/`fix!:` for Conventional Commits.

### 1.4 Examples

Renaming CLI flags/options; changing defaults; modifying directory structure; altering env vars, config keys, or output formats (JSON/CSV).

### 1.5 Scope Enforcement

Internal refactors require consent if any possibility of user-facing impact exists. Request approval when in doubt.

## 2. Resources

- Consent Checklist: See .github/skills/internal-governance/SKILL.md for a ready-to-use prompt.
- Migration Template: See .github/skills/templates/SKILL.md for documenting user-facing changes.

## 3. ARCHITECTURAL SPECIFICATION: THE SPEC PROTOCOL

**Authority:** The Spec Protocol is binding for all significant AI-driven changes in this repository.

**Purpose:** Enforce a hard gate between architectural thinking and code generation. Decisions must be written, persisted, and explicitly approved before implementation begins.

**Scope:** Agent refactors, feature additions, interface alterations, structural reorganizations, and all changes that could impact user-facing surfaces or architectural state.

### 3.1 Spec Protocol Overview

The Spec Protocol enforces **Explicit State Reification**: make the state of architectural decisions explicit, durable, and queryable by persisting them in written artifacts.

**Workflow:**

1. **Thinking Phase:** Analyze, Assess, Draft Plan, Persist to `.github/prompts/`
2. **Approval Phase:** User reviews written plan and approves
3. **[HARD GATE]:** No coding begins until approval is recorded
4. **Coding Phase:** Agent reads plan, verifies "Know Before You Role", executes implementation
5. **Audit Trail:** Commits link back to plan; decisions are permanent and queryable

### 3.2 Reference Documentation

The Spec Protocol (spec-protocol.instructions.md) defines:

- The anti-pattern "Coding While Thinking" and how Spec Protocol prevents it
- Hard gate workflow diagram
- Thinking phase steps (Analyze, Assess, Draft, Persist, Approve)
- Coding phase pre-flight checks ("Know Before You Role")
- Plan prompt structure and naming conventions
- Exemptions for minor changes (typos, syntax fixes)
- Session persistence and crash recovery patterns
- Integration with .github/skills/internal-governance/SKILL.md and .github/skills/templates/SKILL.md

**Key sections in spec-protocol.instructions.md:**

- §1: Purpose & Principles
- §2: The Workflow (Hard Gate Diagram)
- §3: Plan Prompt Structure (naming, minimum contents, exemptions)
- §4: Consent Checklist Integration
- §5: Session Persistence & Recovery
- §8: FAQ

## 4. NON-EPHEMERAL PLANNING

### 4.1 Mandatory Planning for Significant Changes

To avoid ephemeral work and chat, before making any significant change (refactors, feature additions, interface alterations, structural reorganizations), the agent must:

- Perform concise **Analysis** (context, constraints, risks) and **Assessment** (options, trade-offs)
- Draft a **Plan** with clear stages and checkpoints
- **Persist the plan to `.github/prompts/` BEFORE requesting user approval**
- Obtain explicit user approval of the written plan
- **ONLY THEN** proceed to implementation

Exceptions: Minor edits that do not alter behavior or user-facing surfaces may proceed without a saved plan:

- Small syntax fixes, typos, comment tweaks
- Small markdown or documentation edits (formatting, typos, clarifications, link updates)
- Internal variable renames and small refactors (no interface change)

(See spec-protocol.instructions.md §3.3 for full exemption details.)

### 4.2 Plan Prompt Location & Naming

- **Location:** `.github/prompts/` directory in the repository
- **Naming:** `plan-<YYYYMMDD>-<topic>.prompt.md`
- **Example:** `plan-20260124-spectProtocolRefactor.prompt.md`

All plan artifacts are persisted in git, making them durable, queryable, and recoverable.

### 4.3 Plan Prompt Minimum Contents

Every plan must include:

1. **Title & Metadata:** Descriptive title, date, scope, status
2. **Problem Statement:** What is being changed? Why? What problem does it solve?
3. **Analysis & Assessment:** Context, risks, alternatives, trade-offs, impact assessment
4. **Plan:** Ordered stages with objectives, deliverables, and checkpoints
5. **Consent Gate:** Explicit statement of what approval is requested; breaking vs. non-breaking
6. **Persistence & Recovery:** Where artifacts are saved; how to resume after session crash
7. **References:** Links to spec-protocol.instructions.md, relevant standards, related issues

See spec-protocol.instructions.md §3.2 for templates and examples.

## 5. VERIFICATION PROTOCOL (TEST-DRIVEN GENERATION)

### 5.1 The "Verify-First" Mandate

For all logic that changes system state (creating files, changing configs, opening ports), you must generate verification logic **before** or **alongside** the implementation.

### 5.2 Implementation Pattern

Follow the **V-I-V** Pattern:

1. **Verify (Pre-Flight):** Script checks "Can I do this?" (e.g., Test credentials, check disk space).
2. **Implement:** The core logic.
3. **Verify (Post-Flight):** Script checks "Did it work?" (e.g., HTTP 200 OK, File Exists).

*Note: For complex refactors, output the Verification Script as a standalone artifact (e.g., `verify_migration.ps1`) before the Implementation Script.*

## 6. ADVERSARIAL REVIEW PROTOCOL (THE TRIAD)

### 6.1 Purpose

To break the "Self-Correction Bias," critical features must undergo an adversarial audit before final acceptance.

### 6.2 The Review Workflow

1. **The Builder (Standard Mode):** Generates the Plan or Code.

2. **The Trigger:** User commands `/review`.

3. **The Critic (Adversarial Mode):**

    - Context switches to "Lead Auditor."
    - Scans the *previous output* for flaws.
    - Outputs a "Audit Report" (Severity High/Medium/Low).

4. **The Judge (User):**

    - Reviews the Audit Report.
    - Decides: "Fix these issues" OR "Ignore, false positive."

5. **The Resolution:** Agent switches back to Builder mode to implement the fixes.

### 6.3 Audit Scope

The Critic must check against:

- **Spec Compliance:** Does code match the `SPEC_PROTOCOL` plan?
- **Idempotence:** Can this run twice without error?
- **Security:** Are secrets exposed? Are inputs validated?
- **Governance:** Does it follow `STANDARDS_CORE`?

## 7. ARCHITECTURAL DECISION RECORDS (ADR)

### 7.1 Storage Standard

- **Location:** All ADRs must be stored in `.github/adrs/`.
- **Template:** Use the ADR template in .github/skills/templates/SKILL.md as the baseline.
- **Naming:** `ADR-[NUMBER]-[kebab-case-title].md` (e.g., `ADR-005-postgres-migration.md`).

### 7.2 When to Write an ADR

You must propose an ADR when a decision involves a **significant trade-off** or **selects a specific technology/pattern over another**.

- **Examples requiring ADR:**
  - "Using ZeroSSL instead of Let's Encrypt."
  - "Switching from JSON to YAML for config."
  - "Adopting a specific naming convention that differs from industry standard."

### 7.3 The ADR Workflow

1. **Identify:** You (Agent) or the User identify a choice with trade-offs.
2. **Draft:** Create the file in `.github/adrs/`.
3. **Approve:** User reviews and changes Status to "Accepted".
4. **Enforce:** Future Agents MUST read `.github/adrs/` before proposing major changes.

## 8. RECURSIVE OPTIMIZATION (THE CLINIC)

### 8.1 Purpose

To treat behavioral failures as "Governance Bugs" that must be either patched or deprecated. We prioritize **enforceability** over idealism.

### 8.2 The "Clinic" Workflow

**Trigger:** User runs `/retro` (or explicitly asks to "debug the process").

**Process:**

1. **Root Cause Analysis (RCA):** The Agent must audit the recent failure and classify it into one of four categories:
    - **Gap:** The rule did not exist. (Fix: Add Rule)
    - **Ambiguity:** The rule was unclear. (Fix: Clarify Rule)
    - **Conflict:** Two rules contradicted each other. (Fix: Define Precedence)
    - **Constraint:** The rule fights the model's training weights or token limit and fails repeatedly despite prompting. (Fix: **Deprecate**)

2. **The Resolution Proposal:**
    - **If Fixable:** Propose the specific Markdown text change to the relevant Standard.
    - **If Unfixable (Constraint):** Propose **Rule Bankruptcy**. explicitly state: *"This rule has high friction and low compliance. I propose deleting Section [X] to save context."*

3. **Application:**
    - Upon User approval, the Agent applies the edit (Add/Edit/Delete).
    - If a rule is Deprecated, it must be recorded in an ADR (e.g., "ADR-00X: Deprecate Markdown Hygiene Standards").
