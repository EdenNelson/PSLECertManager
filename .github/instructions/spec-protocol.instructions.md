---
name: 'SPEC Protocol'
description: 'Explicit State Reification for Agent Orchestration - binding rules for significant AI-driven changes'
applyTo: '**'
---
# SPEC PROTOCOL: Explicit State Reification for Agent Orchestration

**Authority:** Binding rules for all significant AI-driven changes in this repository.

**Scope:** Agent refactors, feature additions, interface alterations, structural reorganizations, and all changes that could impact user-facing surfaces or architectural state.

**Inheritance:** Complements and enforces guidance in orchestration.instructions.md, general-coding.instructions.md, .github/skills/internal-governance/SKILL.md, and .github/skills/templates/SKILL.md.

---

## 1. PURPOSE & PRINCIPLES

### 1.1 The Anti-Pattern: "Coding While Thinking"

**Problem:** Agents begin code generation before architectural decisions are finalized and written. This leads to:

- Reactive refactoring (code written, then revised)
- Ephemeral decisions (reasoning lost after session ends)
- No audit trail (cannot trace decisions back to rationale)
- Session crash = complete loss of planning context
- Implicit consent (approval without written specs)

**Solution:** Enforce a **hard gate** between thinking and coding.

### 1.2 Explicit State Reification

**Principle:** Make the state of architectural decisions explicit, durable, and queryable.

**Implementation:**

- All significant decisions are written into plan artifacts in `.github/prompts/`
- Artifacts are persisted in the repository (durable, version-controlled)
- Artifacts are queryable (grep, diff, git history, git blame)
- Decision rationale becomes permanent and auditable
- Sessions can resume with full context from artifacts

### 1.3 The "Stop Sequence" (Anti-Exuberance)

**CRITICAL:** When generating a Plan Artifact (`plan**.md`):

1. You must output the Plan Artifact **ONLY**.
2. You must **STOP GENERATING** immediately after the Plan.
3. **DO NOT** generate implementation code, file edits, or scripts in the same response as the Plan.
4. **Wait** for the user to type "Approved" or "Proceed."

**Why:** To prevent "hallucinated consensus," where the Agent assumes the plan is good and implements it instantly, wasting tokens and creating technical debt.

### 1.4 Know Before You Role

**Principle:** Understand the current state, constraints, and approved scope before taking action.

**Implementation:**

- Read the approved plan artifact before beginning implementation
- Verify understanding of Analysis, Assessment, and Stages
- Confirm explicit approval was recorded in the plan
- Check dependencies and hidden constraints
- Validate assumptions before coding

### 1.5 Scribe Artifacts (Pre-Planning Analysis)

**Definition:** A **scribe** is a pre-planning analysis document that captures thinking before a formal plan is drafted.

**Purpose:** Scribes answer:
- What is the problem being analyzed?
- What gap or gap exists in current governance/architecture?
- What is the user's intent?
- What constraints apply?
- What are success criteria?

**Naming Convention:** `scribe-<YYYYMMDD>-<topic>.md` (e.g., `scribe-20260126-governance-maintenance.md`)

**Location:** `.github/prompts/` while active; moved to `.github/prompts/archive/` once superseded by a plan

**Workflow Position:**
```
Scribe (Analysis) → Plan (plan**.md) → Approval → Coding
```

**Lifecycle:** Scribes are typically created to explore a problem space, then superseded by a formal plan. Once a plan is approved and implemented (resulting in an accepted ADR), the scribe is archived. The final ADR should reference superseded scribe reports in its "Prior Analysis" section to preserve the decision trail.

---

## 2. THE SPEC PROTOCOL WORKFLOW

### 2.1 Hard Gate Diagram

```text
┌─────────────────────────────────────────────────────────┐
│                    THINKING PHASE                       │
├─────────────────────────────────────────────────────────┤
│ 1. Analyze: context, constraints, risks                │
│ 2. Assess: options, alternatives, trade-offs           │
│ 3. Draft Plan: stages, checkpoints, expected outputs  │
│ 4. Persist: save in .github/prompts/plan**.md          │
│ 5. Approval: user reviews written spec                 │
└─────────────────────────────────────────────────────────┘
              │
              │ [HARD GATE: No Coding Before Approval]
              ▼
┌─────────────────────────────────────────────────────────┐
│                   CODING PHASE                          │
├─────────────────────────────────────────────────────────┤
│ 1. Read approved plan artifact                          │
│ 2. Verify understanding (Know Before You Role)         │
│ 3. Check dependencies and constraints                   │
│ 4. Execute implementation to plan                       │
│ 5. Link commits back to plan artifact                   │
│ 6. Validate against checkpoints                         │
└─────────────────────────────────────────────────────────┘
```

### 2.2 Thinking Phase (Persisted Before Approval)

#### Step 1: Analyze

- What is being changed and why?
- What are the constraints, risks, dependencies?
- Who is affected?
- What could go wrong?

#### Step 2: Assess

- What are the alternative approaches?
- What are the trade-offs?
- Why is the proposed approach better?
- What is the impact on existing systems?

#### Step 3: Draft Plan

- Organize into clear, ordered stages
- Define checkpoints (decision gates, validation steps)
- Document expected outputs for each stage
- Include rollback strategy
- Link to relevant standards and governance files

#### Step 4: Persist the Plan

- Save as `.github/prompts/plan-<YYYYMMDD>-<topic>.prompt.md`
- Use naming convention: `plan-20260124-spectProtocolRefactor.prompt.md`
- Plan is the "reified state" of the decision

#### Step 5: Request Approval

- User reviews the written plan (Analysis, Assessment, Stages)
- User approves or requests changes
- **No coding begins until explicit approval is recorded in the plan**

### 2.3 Coding Phase (After Approval, With Verification)

**Pre-Flight Check:**

- [ ] Read the approved plan artifact completely
- [ ] Understand the rationale (Analysis & Assessment)
- [ ] Verify stages and checkpoints match expectations
- [ ] Confirm explicit approval is recorded in the plan
- [ ] Identify dependencies on other changes
- [ ] Check for any changed context since approval

**Implementation:**

- Follow the plan stages in order
- Verify each checkpoint before proceeding
- Link git commits to the plan artifact
- No deviations without explicit change approval

**Post-Implementation:**

- Validate against expected outputs
- Verify all checkpoints passed
- Document any surprises or adjustments
- Add final notes to plan artifact

**Approval Recording (Required):**

- Explicit approval must be recorded in the plan with canonical user identity
- Format: `Approved by Eden Nelson on YYYY-MM-DD`
- Example: `Approved by Eden Nelson on 2026-02-18`
- Reference: ADR-0019 (User Identity Attribution)

**Completion Validation (Before Marking Stage Complete):**

- [ ] Run linters on all new and modified files
  - Markdown files: CommonMark spec compliance (no MD031/MD032/MD036/MD040 errors)
  - Code files: Language-specific linters (per bash.instructions.md, powershell.instructions.md, etc.)
  - Fix all errors; do not defer to "later refinement"
- [ ] No file with lint/compliance errors can be marked "complete"
- [ ] Advance to next stage only after validation passes
- [ ] Document any quality issues discovered and how they were resolved

### 2.4 Scribe-Plan Ingestion & Architect Analysis

**Purpose:** Define how Scribe-captured requirements flow to Architect analysis in the **Direct Flow** workflow, ensuring problem classification authority rests with the Architect, not the Scribe.
**Note:** This section describes the direct Scribe → Architect workflow. For complex work requiring systematic research and boundary analysis, see §2.6 Multi-Agent Research Pipeline.
#### Phase 1: Intake & Classification

When receiving N `scribe-plan**.md` files from Scribe intake:

1. **Read all scribe-plan files** in the intake batch
2. **Analyze the actual codebase** for root causes
3. **Reclassify problems** as needed:
   - **Combine:** "Scribe files X and Y describe one root cause"
   - **Split:** "Scribe file Z contains three separate problems"
   - **Reframe:** "Scribe perceived problem as X; actual problem is Y"
4. **Document the mapping:**

```text
Scribe Input → Architect Classification
scribe-plan-A.md → Problem #1 (root cause analysis)
scribe-plan-B.md, scribe-plan-C.md → Problem #2 (combined; same root)
scribe-plan-D.md → Problems #3a, #3b (split; different roots)
```

#### Phase 2: Delivery

Create **one standard plan file** (`plan**.md`) with:

- **Architect's problem classification** (not Scribe's)
- **Mapping** showing how scribe-plans were regrouped and why
- **Root cause analysis** per problem
- **Interdependencies & sequencing** of fixes
- **Implementation roadmap** reflecting Architect's technical judgment

#### Authority Boundary

- **Scribe authority:** Capture user intent accurately
- **Architect authority:** Determine actual problems and how to solve them
- **Scribe does NOT dictate:** Problem count, root causes, or solution grouping

#### Success Criteria

- Architect's classification is **traceable back to scribe-plans** (audit trail)
- If Architect regroups/splits, **rationale is documented**
- Standard plan **reflects Architect's technical judgment**, not Scribe's structure

### 2.5 Agent Activation & Mode Switching

**Principle:** Scribe and Architect agents are mutually exclusive. Sessions default to Architect unless `/scribe` is explicitly invoked. If `/scribe` is invoked, the session remains Scribe until explicitly exited; otherwise it remains Architect.

**Rules:**

- Default agent: Architect (`.github/agents/architect.agent.md`)
- Scribe mode is entered only when the user types `/scribe` or explicitly requests intake; Scribe stays active until the intake loop ends and the user exits
- When reviewing scribe-plan files per §2.4, activate Architect agent only; Scribe Prime Directives do not apply
- Agent activation is explicit; agents are not chain-loaded

**Context Verification:**

- Use the context verification command (see .github/copilot-instructions.md) to report currently active agent: architect or scribe (from `.github/agents/`), active baseline instructions, and loaded standards skills
- If .github/copilot-instructions.md was not auto-loaded (e.g., workspace load issue), manually load .github/copilot-instructions.md then re-run context verification
### 2.6 Multi-Agent Research Pipeline
**Purpose:** For complex work requiring systematic research, boundary analysis, and technical synthesis, AgentGov provides a 5-stage pipeline that separates research concerns from implementation.
#### 2.6.1 When to Use Pipeline vs. Direct Flow
**Use Direct Flow (Scribe → Architect):**
- Single-file changes or small refactors
- Documentation updates and typo fixes
- Well-understood problems with clear solutions
- Time-sensitive fixes requiring rapid implementation
**Use Multi-Agent Pipeline (Scribe → Code Planner → Edge Planner → Planning Architect → Architect):**
- Complex refactors spanning multiple files/modules
- Multi-system changes with integration points
- Work requiring dependency mapping and impact analysis
- High-risk changes needing boundary value analysis
- Architectural decisions requiring trade-off evaluation
#### 2.6.2 Pipeline Stages and Artifacts
```text
┌─────────────────────────────────────────────────────────────┐
│                    MULTI-AGENT PIPELINE                     │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Scribe          Code Planner      Edge Planner            │
│     ↓                  ↓                  ↓                 │
│  scribe-plan    code-context    risk-assessment            │
│     ↓                  ↓                  ↓                 │
│     └──────────────────┴──────────────────┘                │
│                        ↓                                    │
│              Planning Architect                             │
│                        ↓                                    │
│                  draft-plan                                 │
│                        ↓                                    │
│              [USER REVIEW & APPROVAL]                       │
│                        ↓                                    │
│                  plan**.md                                  │
│                        ↓                                    │
│                   Architect                                 │
│                        ↓                                    │
│                 implementation                              │
└─────────────────────────────────────────────────────────────┘
```
**Stage 1: Scribe** (`.github/agents/scribe.agent.md`)
- **Input:** User requirements and pain points
- **Output:** `scribe-plan-<YYYYMMDD>-<topic>.md`
- **Focus:** What/Why (problem statement, user intent, constraints, success criteria)
**Stage 2: Code Planner** (`.github/agents/code-planner.agent.md`)
- **Input:** `scribe-plan**.md`
- **Output:** `code-context-<YYYYMMDD>-<topic>.md`
- **Focus:** Where (current code patterns, file locations, established conventions)
- **State Management:** Marks scribe-plan with `status: ingested` in frontmatter
**Stage 3: Edge Planner** (`.github/agents/edge-planner.agent.md`)
- **Input:** `scribe-plan**.md` + `code-context**.md`
- **Output:** `risk-assessment-<YYYYMMDD>-<topic>.md`
- **Focus:** What Could Fail (boundary value analysis, state transitions, fault injection)
- **State Management:** Marks code-context with `status: reviewed` in frontmatter
**Stage 4: Planning Architect** (`.github/agents/planning-architect.agent.md`)
- **Input:** `scribe-plan**.md` + `code-context**.md` + `risk-assessment**.md`
- **Output:** `draft-plan-<YYYYMMDD>-<topic>.md`
- **Focus:** How (conflict resolution, technical specification, phased implementation)
- **State Management:** Marks risk-assessment with `status: synthesized` in frontmatter
**Stage 5: Architect** (`.github/agents/architect.agent.md`)
- **Input:** `draft-plan**.md` (after promotion to `plan**.md`)
- **Output:** Implementation commits
- **Focus:** Execution (code generation, testing, validation)
- **Tools:** Full access
#### 2.6.3 Activation Mechanism
**Manual Activation:**
Users activate pipeline agents explicitly with commands:
- `/scribe` → Start intake session
- `/codeplanner` → Activate Code Planner for current scribe-plan
- `/edgeplanner` → Activate Edge Planner for current code-context
- `/planningarchitect` → Activate Planning Architect for synthesis
**Agent Handoff:**
Each pipeline agent declares completion and suggests next agent:
```markdown
Code Context saved to code-context-20260221-example.md
Scribe Plan marked as `status: ingested`
Handoff: Ready for Edge Planner (`/edgeplanner`)
```
**Context Verification:**
Use `/context` to verify active pipeline agent and loaded artifacts.
#### 2.6.4 State Management and Frontmatter Status
**Frontmatter Status Tags:**
Pipeline agents use frontmatter tags to track progression and prevent duplicate work:
## ```yaml
## status: ingested  # Added by Code Planner to scribe-plan
```
## ```yaml
## status: reviewed  # Added by Edge Planner to code-context
```
## ```yaml
## status: synthesized  # Added by Planning Architect to risk-assessment
```
**Verification Pattern:**
Each pipeline agent checks for completion status before starting:
1. Read predecessor artifact
2. Check frontmatter for status tag
3. If status exists, exit with message: "This artifact has already been processed"
4. Otherwise, proceed with research/analysis
5. Upon completion, append status tag to predecessor artifact
**Immutability Note:**
While status tags modify artifacts, the core content remains immutable. Only metadata (frontmatter) changes to track workflow state.
#### 2.6.5 Artifact Lifecycle and Archive Strategy
**Active Directory:**
All pipeline artifacts are created in `.github/prompts/` during active work:
- `scribe-plan-<YYYYMMDD>-<topic>.md`
- `code-context-<YYYYMMDD>-<topic>.md`
- `risk-assessment-<YYYYMMDD>-<topic>.md`
- `draft-plan-<YYYYMMDD>-<topic>.md`
**Promotion Workflow:**
After Planning Architect creates `draft-plan**.md`:
1. **User Review:** User reviews draft-plan for completeness and accuracy
2. **User Approval:** User provides explicit approval
3. **Promotion:** Rename `draft-plan**.md` to `plan**.md` (matches Spec Protocol convention)
4. **Record Approval:** Add approval signature to plan: `Approved by Eden Nelson on YYYY-MM-DD`
**Archive Strategy:**
After plan approval and implementation completion:
1. Create subdirectory: `.github/prompts/archive/<YYYYMMDD>-<topic>/`
2. Move all pipeline artifacts into subdirectory:
   - `scribe-plan**.md`
   - `code-context**.md`
   - `risk-assessment**.md`
   - `draft-plan**.md` (if not deleted after promotion)
3. Keep final `plan**.md` in `.github/prompts/` root for audit trail
4. Commit archive move with reference to implementation commits
**Archive Pattern:**
```text
.github/prompts/
├── plan-20260221-example.md          # Final approved plan (audit trail)
├── archive/
│   └── 20260221-example/              # Pipeline research artifacts
│       ├── scribe-plan-20260221-example.md
│       ├── code-context-20260221-example.md
│       ├── risk-assessment-20260221-example.md
│       └── draft-plan-20260221-example.md
```
#### 2.6.6 Integration with Spec Protocol Hard Gates
**Hard Gate Enforcement:**
The multi-agent pipeline operates **within** the Spec Protocol hard gate:
```text
THINKING PHASE (Pipeline Research)
  Scribe → Code Planner → Edge Planner → Planning Architect
                              ↓
                        draft-plan**.md
                              ↓
                    [USER REVIEW & APPROVAL]
                              ↓
══════════════════════ HARD GATE ══════════════════════
                              ↓
                        plan**.md (approved)
                              ↓
CODING PHASE
                         Architect
                              ↓
                      implementation
```
**Approval Gate:**
- No coding begins until draft-plan is reviewed, approved, and promoted to plan**.md
- Architect reads plan**.md (not draft-plan**.md) during Coding Phase
- Consent Checklist applies if plan includes breaking changes
**Checkpoint Integration:**
Pipeline artifacts serve as intermediate checkpoints within the Thinking Phase, enabling recovery if session crashes during research.
##
## 3. PLAN PROMPT STRUCTURE

### 3.1 Naming Convention

```text
.github/prompts/plan-<YYYYMMDD>-<topic>.prompt.md
```

**Examples:**

- `plan-20260124-spectProtocolRefactor.prompt.md` (this refactoring)
- `plan-20260125-migrateConfigFormat.prompt.md` (user-facing breaking change)
- `plan-20260126-refactorAuthModule.prompt.md` (internal restructuring)

### 3.2 Minimum Required Sections

Every plan must include:

1. **Title & Metadata:** Descriptive title, date, scope, status
2. **Problem Statement:** What is being changed? Why? What problem does it solve?
3. **Analysis & Assessment:** Context, risks, alternatives, trade-offs, impact assessment
4. **Plan:** Ordered stages with objectives, deliverables, and checkpoints
5. **Consent Gate:** Explicit statement of what approval is requested; breaking vs. non-breaking
6. **Persistence & Recovery:** Where artifacts are saved; how to resume after session crash
7. **References:** Links to spec-protocol.instructions.md, relevant standards, related issues

### 3.3 Exempt Changes (No Plan Required)

Minor changes that may proceed **without** a persisted plan:

- **Syntax fixes:** Correcting typos, formatting, indentation (no behavior change)
- **Comment improvements:** Clarifying comments, updating examples (no code change)
- **Documentation edits:** Link fixes, typo corrections, wording clarity (no guidance change)
- **Small refactors:** Variable renames, method extractions (internal only, no interface change)

**Rule of Thumb:** If the change could affect any user-facing surface, workflow, API, config, or output format — create a plan. When in doubt, create a plan.

---

## 4. INTEGRATION WITH CONSENT CHECKLIST

### 4.1 Updated Approval Flow

**Old Flow (Implicit Consent):**

1. Propose (verbal/chat)
2. Ask (user approves in chat)
3. Implement (coding phase)
4. Done (no durable record)

**New Flow (Explicit Consent via Spec Protocol):**

1. **Analyze & Assess** (thinking phase, write down reasoning)
2. **Draft & Persist Plan** (save to `.github/prompts/plan**.md`)
3. **Request Approval** (user reviews written plan)
4. **Explicit Approval** (user confirms in writing; recorded in plan)
5. **Implement** (coding phase, with "Know Before You Role" verification)
6. **Link & Audit** (commits reference plan; audit trail is complete)

### 4.2 Consent Checklist Integration

Before approving any breaking/major change:

1. **Is there a persisted plan artifact in `.github/prompts/`?**
   - Yes → proceed to step 2
   - No → request that agent create and persist plan first

2. **Does the plan include:**
   - Problem Statement / Executive Summary
   - Analysis & Assessment (context, risks, alternatives)
   - Ordered stages with checkpoints
   - Explicit consent gate section
   - References to relevant standards

3. **Do you understand and approve:**
   - The rationale for the change
   - The stages and approach
   - The risks and rollback strategy
   - The user impact assessment

4. **Record Approval:**
   - Add sign-off line to plan: `Approved by USERNAME on DATE`
   - User explicitly confirms: "Yes, proceed with this plan"

5. **Implement:**
   - Agent reads and verifies plan before coding
   - Agent links commits to plan artifact
   - All checkpoints are verified before moving to next stage

---

## 5. SESSION PERSISTENCE & RECOVERY

### 5.1 If Session Crashes

**Before:** Planning context is lost; recovery requires re-thinking from scratch.

**Now:**

1. All planning artifacts are saved in `.github/prompts/` (in git)
2. Agent can clone the repo and read the plan
3. Recovery is as simple as: `cat .github/prompts/plan-<topic>.prompt.md`
4. Implementation can resume from the last completed checkpoint

### 5.2 Durable Checkpoints

Each stage in the plan has a checkpoint that serves as a "recovery anchor":

```markdown
### STAGE 1: Create SPEC_PROTOCOL.md

**Deliverables:**
- [ ] SPEC_PROTOCOL.md created with full spec
- [ ] All sections (1-6) documented
- [ ] Examples included

**Checkpoint:** SPEC_PROTOCOL.md reviewed and approved
```

If implementation stops after Checkpoint 1, the next session:

1. Reads the plan
2. Sees Checkpoint 1 is complete
3. Proceeds to Stage 2 without re-doing Stage 1

### 5.3 Git as Audit Trail

Each commit linking to the plan becomes part of the durable record:

```bash
git commit -m "Stage 1: Create SPEC_PROTOCOL.md

Ref: .github/prompts/plan-20260124-spectProtocolRefactor.prompt.md
Part of: Implicit Permission → Explicit State Reification refactoring
Checkpoint: SPEC_PROTOCOL.md created and reviewed"
```

---

## 6. EXAMPLES

### 6.1 Example Plan: Renaming a Config Key (Breaking Change)

**File:** `.github/prompts/plan-20260125-renameConfigKey.prompt.md`

**Content Structure:**

```markdown
# PLAN: Rename Config Key from `defaultTimeout` to `requestTimeout`

**Date:** January 25, 2026
**Status:** Approved
**Scope:** User-facing breaking change

## Problem Statement

Current config key `defaultTimeout` is ambiguous. Renaming to `requestTimeout` clarifies intent and aligns with internal naming conventions.

## Analysis & Assessment

- Risk: Breaking change; users with config files must migrate
- Alternative: Keep old key and add deprecation warning (deferred)
- Rationale: Direct rename is cleaner; migration path is simple

## Plan

### Stage 1: Update code to use new key (internal only)
### Stage 2: Add migration helper
### Stage 3: Update docs and examples
### Stage 4: Release with breaking change note

[Full plan with checkpoints...]

## Consent Gate

- Breaking change: **Yes**
- Affects: Config files, environment variables, documentation
- User action: Rename `defaultTimeout` to `requestTimeout` in config
- Approved: [✓] User confirms breaking change is acceptable
```

### 6.2 Example Plan: Internal Refactor (Non-Breaking)

**File:** `.github/prompts/plan-20260126-refactorAuthModule.prompt.md`

**Content Structure:**

```markdown
# PLAN: Refactor Auth Module for Clarity

**Date:** January 26, 2026
**Status:** Approved
**Scope:** Internal refactor; no user-facing changes

## Problem Statement

Auth module is tangled. Refactoring improves maintainability and testability.

## Analysis & Assessment

- Risk: Low (no public API change)
- Testing: Existing tests must pass; no new tests needed
- Timeline: 2-3 sessions

## Plan

### Stage 1: Extract token validation logic
### Stage 2: Extract session management logic
### Stage 3: Update internal imports
### Stage 4: Run tests

[Full plan with checkpoints...]

## Consent Gate

- Breaking change: **No**
- User-facing impact: **None**
- Internal impact: Module structure changes; imports may need update
- Approved: [✓] User confirms internal refactor is acceptable
```

---

## 7. GOVERNANCE & STANDARDS INTEGRATION

### 7.1 Relationship to orchestration.instructions.md

**orchestration.instructions.md** defines the **requirement** to obtain user consent for breaking changes (§1 Consent Gate).

**spec-protocol.instructions.md** defines the **mechanism** for obtaining consent: written architectural specs that are analyzed, assessed, planned, and approved before coding begins.

**Integration:**

- orchestration.instructions.md §1.1: "Consent Gate (Mandatory)" ← Now requires Spec Protocol plan as input
- orchestration.instructions.md §1.2: "Required Approval Flow" ← Now flows through Spec Protocol (Plan → Approve → Implement)

### 7.2 Relationship to Consent Checklist

**Consent Checklist** (in .github/skills/internal-governance/SKILL.md) is a **reactive prompt** used when a breaking change is announced.

**Spec Protocol** (this file) is **proactive governance** that prevents breaking changes from being proposed without planning first.

**Workflow:**

1. Agent creates plan (Spec Protocol workflow)
2. Agent requests approval using Consent Checklist
3. Consent Checklist now asks: "Does the plan exist and include all required sections?"

### 7.3 Relationship to Core Standards

**general-coding.instructions.md §1.1 Core Values:** "Correctness, Clarity, and Idempotence > Brevity"

**Spec Protocol enforcement:** Plans must be correct (accurate analysis), clear (understandable assessment), and idempotent (repeatable stages).

---

## 8. FREQUENTLY ASKED QUESTIONS

### Q: Does every change need a plan?

**A:** No. Minor changes (typos, syntax fixes, small internal refactors) are exempt. See §3.3. If you're unsure, create a plan.

### Q: What if the plan changes mid-implementation?

**A:** Update the plan artifact. Note the change, reason, and date. Commit the updated plan. Get user re-approval if scope changes significantly.

### Q: What if a session crashes during implementation?

**A:** Read the plan artifact; see the last completed checkpoint. Resume from there. Durable checkpoints enable recovery.

### Q: Who reviews the plan?

**A:** The user. The plan is written for the user to understand, evaluate, and approve before coding.

### Q: Can agents skip the plan if they "just know" what to do?

**A:** No. The Spec Protocol is non-optional for significant changes. Knowing how to do something ≠ understanding the full impact and trade-offs.

### Q: How does Spec Protocol differ from a PR description?

**A:** A plan is created **before coding**. A PR description is created **after coding**. Plans enforce thinking-before-coding. PR descriptions document what was already done.

---

## 9. REFERENCES

- **orchestration.instructions.md** § 1–4 (Consent Gate and Non-Ephemeral Planning)
- **.github/skills/internal-governance/SKILL.md** (User approval gates and consent checklist)
- **.github/skills/templates/SKILL.md** (User-facing change documentation and ADR template)
- **general-coding.instructions.md** (Core values: Correctness, Clarity, Idempotence)
