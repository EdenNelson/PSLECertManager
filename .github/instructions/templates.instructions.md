---
name: 'ADR and Migration Templates'
description: 'Templates for Architectural Decision Records and migration guides'
applyTo: '**/*.md'
---
# ADR and Migration Templates

## ADR Template: ADR-[NUMBER]: [Title]

### Status

[Proposed | Accepted | Rejected | Deprecated | WONTFIX]

### Date

[YYYY-MM-DD]

### Deciders

Eden Nelson

### Context

The issue motivating the decision. Describe the tension between available options.
(e.g., "We need a database, but we have limited budget and high concurrency requirements.")

### Decision

The change that we are proposing or have agreed to implement.
(e.g., "We will use PostgreSQL instead of MySQL.")

### Consequences

What becomes easier? What becomes harder?

- **Positive:** [Benefit 1]
- **Negative:** [Trade-off / Cost]
- **Risks:** [New complexity introduced]

### Compliance

- **Standards:** Does this comply with STANDARDS_CORE?
- **Governance:** Does this impact specific user workflows?

---

## For Governance Maintenance ADRs (Optional Sections Below)

### Suspect List (Phase 1)

| Rule/Section | Category | Rationale |
| --- | --- | --- |
| [Rule ID] | Invalid / Superseded / Conflicting / Token Waste | Brief explanation |

**Categories:**
- **Invalid:** Rule refers to non-existent patterns or outdated frameworks
- **Superseded:** Another rule now covers this; deduplication opportunity
- **Conflicting:** Two rules contradict each other
- **Token Waste:** Rule is overly verbose or redundant

### Test Plan (Phase 2)

**Target Rule:** [Which rule from Suspect List]

**Probe Design:**
- **Context:** [How to set up the test (clear chat, load standards)]
- **Input:** [Exact prompt that violates the rule]
- **Assertion:** [What the agent should do if rule is working]
- **Pass Criteria:** [How to measure success]

### Execution Notes (Phase 3)

**Date:** [YYYY-MM-DD]

**Baseline (Current Standards):**
- Result: [Pass/Fail]
- Behavior Observed: [What happened]

**Change Applied:**
```
[Diff or description of modification]
```

**Post-Change (Modified Standards):**
- Result: [Pass/Fail]
- Behavior Observed: [What happened]

**Regression Verdict:** [Passed / Failed]

### Validation Results (Phase 4)

**Decision:** [Accepted / Rejected]

**Rationale:** [Why this decision was made based on test results]

**Integration Status:** [Rule updated in governance files / Reverted / Deferred]

**Approval:** [User approval confirmation and date]

---

## Migration Template: Migration Guide: [CHANGE_TITLE]

### Summary

Brief description of the breaking/major change and the rationale.

### Affected Surfaces

- CLI: [FLAGS/COMMANDS/ARGUMENTS]
- API: [ENDPOINTS/SCHEMAS/CONTRACTS]
- Configuration: [KEYS/PATHS/DEFAULTS]
- Environment: [VARIABLES]
- Filesystem/Formats: [LAYOUT, FILE NAMES, DATA FORMATS]

### Who Is Impacted

Describe which users, scripts, or workflows are affected and how.

### Architectural Planning (Agent Reference)

If this change was designed using the Spec Protocol, reference the plan artifact:

- **Plan Artifact:** `.github/prompts/plan-<YYYYMMDD>-<topic>.prompt.md`
- **Analysis:** See plan for full context, risks, and alternatives considered
- **Approval:** Approved by [USER] on [DATE]
- **Rationale:** [Summary of key decisions made in the plan]

For new architectural changes, create a plan artifact BEFORE implementation (see spec-protocol.instructions.md).

### Steps to Migrate

1. [STEP 1]
2. [STEP 2]
3. [STEP 3]

### Examples (Before → After)

- Example 1:
  - Before: [OLD USAGE]
  - After: [NEW USAGE]

### Rollback Strategy

How to revert the change quickly and safely if necessary.

### Validation

How to verify the migration was successful.

### Notes

Additional considerations, edge cases, or known limitations.
