---
name: 'Markdown Hygiene'
description: 'CommonMark compliance and strict formatting standards for all markdown files'
applyTo: '**/*.md'
---

# AI CODING STANDARDS: MARKDOWN HYGIENE

**AUTHORITY:** These rules are mandatory for all markdown file creation and editing in this repository.

**SCOPE:** All markdown files (*.md) across the entire repository.

**INHERITANCE:** Complements general-coding.instructions.md and templates.instructions.md.

## 1. COMMONMARK COMPLIANCE

All markdown files must follow the [CommonMark specification](https://commonmark.org/).

### 1.1 Required Formatting

- **Blank lines:** Required before and after headings and lists
- **Code fences:** Must specify language (e.g., ```bash, ```powershell, ```markdown, ```json)
- **Final newline:** All files must end with a single newline character
- **Line length:** Prefer 120 characters; hard limit 200 characters (except URLs and tables)

### 1.2 Headings

- Use ATX-style headings (`#`, `##`, `###`) not Setext-style (`===`, `---`)
- One blank line before and after each heading
- Do not use emphasis (bold/italic) as heading substitutes

### 1.3 Lists

- One blank line before and after lists
- Use consistent list markers within a file (prefer `-` for unordered, `1.` for ordered)
- Indent nested lists by 2 spaces

### 1.4 Code Blocks

- Always specify language for fenced code blocks
- Use triple backticks with language identifier (```bash, ```powershell, etc.)
- No language identifier allowed only for plain text examples

## 2. EMOJI POLICY (STRICT)

**PROHIBITED:** Emojis in ALL markdown files, NO EXCEPTIONS.

### 2.1 Rationale

Emojis consume extremely high token counts (3-4x more than text equivalents), directly impacting:
- Context window budget
- API costs
- Agent performance
- File size and processing time

### 2.2 Text Equivalents (Required)

Use these text replacements for common status and warning indicators:

| Emoji | Text Equivalent | Purpose |
|-------|----------------|---------|
| [COMPLETE] | `[COMPLETE]` or `[DONE]` | Completed tasks, approved items |
| [PENDING] | `[PENDING]` or `[IN-PROGRESS]` | Work in progress, awaiting action |
| [REJECTED] | `[REJECTED]` or `[FAILED]` | Rejected proposals, failed tests |
| [WARNING] | `[WARNING]` or `[CAUTION]` | Warnings, important notices |
| [CRITICAL] | `[CRITICAL]` or `[STOP]` | Critical issues, blocking problems |
| 🔍 | `[REVIEW]` | Items requiring review |
| 📝 | `[NOTE]` | Additional notes or context |
| 💡 | `[TIP]` | Helpful tips or suggestions |

### 2.3 Enforcement

Before outputting any markdown file or edit:
1. **Scan** for ANY emoji characters (Unicode ranges U+1F300–U+1F9FF and related)
2. **Replace** with appropriate text equivalents from table above
3. **Verify** zero emojis remain in output
4. **Reject** any markdown file containing emojis during validation

## 3. ACCESSIBILITY STANDARDS

### 3.1 Link Text

- Use descriptive link text (not "click here" or "read more")
- Avoid bare URLs in prose; wrap in meaningful link text

### 3.2 Image Alt Text

- All images must have descriptive alt text
- Format: `![Descriptive alt text](path/to/image.png)`

### 3.3 Tables

- Use proper table syntax with header row
- Include alignment indicators (`:---`, `:---:`, `---:`)

## 4. ENFORCEMENT CHECKLIST

Before outputting any markdown file, verify:

- [ ] Blank lines before/after all headings
- [ ] Blank lines before/after all lists
- [ ] All code fences have language specifiers
- [ ] File ends with single newline
- [ ] **ZERO emojis present** (scan for Unicode emoji ranges)
- [ ] All links have descriptive text
- [ ] All images have alt text
- [ ] Tables use proper syntax

## 5. VALIDATION

The `.github/scripts/validate-markdown.sh` script enforces these standards:

- CommonMark compliance (via markdownlint)
- Strict emoji ban (rejects any emoji in any markdown file)
- Code fence language specifiers
- Final newline presence

Run validation before committing markdown changes:

```bash
.github/scripts/validate-markdown.sh path/to/file.md
```

## 6. REFLEXION PROTOCOL

Per general-coding.instructions.md §3.1, perform internal review before output:

1. **Draft:** Generate markdown content internally
2. **Critique:** 
   - Check CommonMark compliance (blank lines, code fences, final newline)
   - **Scan for emojis** (CRITICAL: must be zero)
   - Verify accessibility (links, alt text)
3. **Fix:** Replace any emojis with text equivalents; correct formatting violations

If you catch and correct violations during review, optionally append:
> **Reflexion:** I initially included emoji status indicators but self-corrected to text equivalents per markdown.instructions.md §2.
