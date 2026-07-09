# Quality Validation Hooks
Automated quality validation system using VS Code agent hooks to enforce coding standards after file edits.
## Overview
The quality validation system automatically runs linters and validators after file modifications, ensuring code quality and standards compliance before changes are complete.
-*Hook Types:** `PreToolUse`, `PostToolUse`
-*PreToolUse Triggers On:**
- `create_file`
- `replace_string_in_file`
- `multi_replace_string_in_file`
- `edit_notebook_file`
-*PostToolUse Triggers On:**
- `create_file`
- `replace_string_in_file`
- `multi_replace_string_in_file`
- `edit_notebook_file`
## Validated File Types
| File Type | Validator | Standards Enforced |
| --------- | --------- | ------------------ |
| `.github/skills/*/SKILL.md` | [validate-skills.sh](.github/scripts/validate-skills.sh) | YAML frontmatter with `name` and `description` |
| `*.md` | [validate-markdown.sh](.github/scripts/validate-markdown.sh) | CommonMark spec (MD031, MD032, MD036, MD040) |
| `*.sh` | [validate-bash.sh](.github/scripts/validate-bash.sh) | Bash strict mode, shellcheck compliance |
| `*.ps1`, `*.psm1`, `*.psd1` | [validate-powershell.sh](.github/scripts/validate-powershell.sh) | Line endings (LF), encoding, PSScriptAnalyzer |
## How It Works
1. **Agent edits a file** → PreToolUse hook fires
2. **Signature prep** ([prep-file.sh](.github/scripts/prep-file.sh)) dispatches PowerShell prep
3. **PowerShell prep** ([prep-powershell.sh](.github/scripts/prep-powershell.sh)) strips signature blocks
4. **Agent edits a file** → PostToolUse hook fires
5. **Hook dispatcher** ([validate-file.sh](.github/scripts/validate-file.sh)) receives hook input
6. **File-specific validator** runs based on file extension
7. **Validation results:**
  - [COMPLETE] **Pass:** Agent continues normally
  - [REJECTED] **Fail:** Validation errors are injected as `additionalContext` for the agent to fix
## Validator Behavior
Each validator has two modes:
### Full Validation
When linting tools are installed:
- **Markdown:** Uses `markdownlint-cli` (falls back to basic checks if not installed)
- **Bash:** Uses `shellcheck` (falls back to basic checks if not installed)
- **PowerShell:** Uses `PSScriptAnalyzer` (**REQUIRED - validation fails if not installed**)
  - Checks: cmdlet best practices, parameter usage, performance, security
  - Excludes: PSAvoidUsingWriteHost (handled separately)
  - Reports: [Severity] Line number (RuleName): Message
  - Full guide: [PSSCRIPTANALYZER-GUIDE.md](PSSCRIPTANALYZER-GUIDE.md)
### Basic Validation (fallback)
When tools are not installed:
- **Markdown:** Final newline, no emojis, code block language tags
- **Bash:** Shebang, strict mode header, basic syntax patterns
- **PowerShell:** **Validation fails - PSScriptAnalyzer is mandatory**
## Installation
### Required Tools
For PowerShell validation to work, PSScriptAnalyzer **must** be installed:
```bash
pwsh -Command "Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force"
```
-*Without PSScriptAnalyzer, PowerShell file validation will fail.**
### Optional Tools (Enhanced)
For enhanced validation of other file types:
```bash
# Markdown
npm install -g markdownlint-cli
# Bash
brew install shellcheck  # macOS
# or: apt-get install shellcheck  # Linux
```
## Testing
Test validators manually:
```bash
# Test markdown validation
.github/scripts/validate-markdown.sh README.md
# Test bash validation
.github/scripts/validate-bash.sh .github/scripts/validate-file.sh
# Test PowerShell validation
.github/scripts/validate-powershell.sh some-script.ps1
```
## Configuration
### Hook Configuration
Edit [quality-validation.json](.github/hooks/quality-validation.json):
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "type": "command",
        "command": ".github/scripts/prep-file.sh",
        "timeout": 30,
        "cwd": "."
      }
    ],
    "PostToolUse": [
      {
        "type": "command",
        "command": ".github/scripts/validate-file.sh",
        "timeout": 30,
        "cwd": ".",
        "env": {
          "VALIDATION_MODE": "hook"
        }
      }
    ]
  }
}
```
### Markdownlint Rules
Edit [markdownlint.json](.github/config/markdownlint.json) to customize Markdown rules:
```json
{
  "MD031": true,  // Blank lines around fenced code
  "MD032": true,  // Blank lines around lists
  "MD036": true,  // No emphasis as heading
  "MD040": true   // Fenced code language
}
```
## Disabling Validation
### Temporarily disable
Delete or rename the hook file:
```bash
mv .github/hooks/quality-validation.json .github/hooks/quality-validation.json.disabled
```
### Disable for specific file types
Edit [validate-file.sh](.github/scripts/validate-file.sh) and comment out the file pattern:
```bash
case "$file" in
  *.md)
    validator=".github/scripts/validate-markdown.sh"
    ;;
  # *.sh)  # Disabled bash validation
  #   validator=".github/scripts/validate-bash.sh"
  #   ;;
```
## Troubleshooting
### View hook output
1. Open **Output** panel (Cmd+Shift+U / Ctrl+Shift+U)
2. Select **GitHub Copilot Chat Hooks** from dropdown
3. View validation results and errors
### Check hook diagnostics
1. Right-click in Chat view → **Diagnostics**
2. Look for **hooks** section
3. Verify hook is loaded and no configuration errors
### Common issues
-*Hook not executing:**
- Verify hook file is in `.github/hooks/` with `.json` extension
- Check scripts have execute permissions (`chmod +x`)
- Confirm VS Code version is 1.109.3 or later
-*Permission denied:**
```bash
chmod +x .github/scripts/validate-*.sh
```
-*Timeout errors:**
- Increase timeout in hook config: `"timeout": 60`
- Optimize validator scripts
## Standards References
- [Spec Protocol](../.github/instructions/spec-protocol.instructions.md) § 2.3 (Completion Validation)
- [General Coding Standards](../.github/instructions/general-coding.instructions.md) § 1.3 (Markdown Hygiene)
- [Bash Standards](../.github/instructions/bash.instructions.md) § 1 (Strict Mode)
- [PowerShell Standards](../.github/instructions/powershell.instructions.md) § File Encoding
## Architecture
```text
PreToolUse Hook
  ↓
prep-file.sh
  ↓
prep-powershell.sh
  ↓
PostToolUse Hook
       ↓
validate-file.sh (dispatcher)
       ↓
    ┌──────┬──────────┬────────────┐
    ↓      ↓          ↓            ↓
 *.md    *.sh    *.ps1/*.psm1   (other)
    ↓      ↓          ↓            ↓
validate- validate- validate-   [skip]
markdown  bash      powershell
    ↓      ↓          ↓
  [Uses markdownlint, shellcheck, PSScriptAnalyzer if available]
    ↓      ↓          ↓
  [Falls back to basic validation checks]
    ↓      ↓          ↓
   Pass or Fail with additionalContext
```
## Files
```text
.github/
├── hooks/
│   └── quality-validation.json       # Hook configuration
├── scripts/
│   ├── prep-file.sh                   # PreToolUse dispatcher
│   ├── prep-powershell.sh             # PowerShell signature remover
│   ├── validate-file.sh              # Hook dispatcher
│   ├── validate-markdown.sh          # Markdown validator
│   ├── validate-bash.sh              # Bash validator
│   └── validate-powershell.sh        # PowerShell validator
└── config/
    └── markdownlint.json             # Markdown linting rules
```
## Future Enhancements
Potential additions:
- **PreToolUse hooks** to block dangerous operations
- **SessionStart hooks** to inject project context
- **Stop hooks** to enforce test runs before completion
- Additional validators (Python, TypeScript, YAML, JSON)
- Auto-formatting (not just validation)
- Integration with CI/CD pipelines
## Related Documentation
- [PSScriptAnalyzer Integration Guide](PSSCRIPTANALYZER-GUIDE.md) - Comprehensive PowerShell static analysis
- [VS Code Agent Hooks Documentation](https://code.visualstudio.com/docs/copilot/customization/hooks)
- [AgentGov Governance Framework](.github/instructions/)
