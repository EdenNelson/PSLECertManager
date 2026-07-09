# PSScriptAnalyzer Integration Guide

Complete guide for PowerShell static analysis using PSScriptAnalyzer in the AgentGov quality validation system.

## Overview

[PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) is a static code analyzer for PowerShell that checks scripts against a set of best practice rules. The AgentGov quality validation system automatically runs PSScriptAnalyzer after every PowerShell file edit during agent sessions.

## Installation

**CRITICAL:** PSScriptAnalyzer is **required** for PowerShell validation. Files cannot be validated without it.

### Quick Install

```bash
pwsh -Command "Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force"
```

### Verify Installation

```bash
pwsh -Command "Get-Module -ListAvailable -Name PSScriptAnalyzer"
```

### Manual Testing

```powershell
# In PowerShell
Import-Module PSScriptAnalyzer
Invoke-ScriptAnalyzer -Path ./script.ps1
```

## How It's Integrated

### Hook Workflow

```text
Agent edits *.ps1, *.psm1, or *.psd1
       ↓
PostToolUse hook fires
       ↓
validate-powershell.sh runs
       ↓
┌─────────────────────────────────┐
│ Basic Checks (always run)        │
│  - Line endings (LF/CRLF)        │
│  - Encoding (UTF-8)              │
│  - Write-Host detection          │
│  - Explicit parameter names      │
└────────────┬────────────────────┘
             ↓
┌─────────────────────────────────┐
│ PSScriptAnalyzer (if installed)  │
│  - Severity: Error, Warning      │
│  - Comprehensive rule checks     │
│  - Formatted output with line #  │
└────────────┬────────────────────┘
             ↓
      Pass or Fail
```

### What Gets Checked

PSScriptAnalyzer runs with the following configuration:

```powershell
Invoke-ScriptAnalyzer -Path $file -Severity Error,Warning -ExcludeRule PSAvoidUsingWriteHost
```

**Severity Levels:**

- `Error` - Critical issues that must be fixed
- `Warning` - Best practice violations that should be fixed

**Excluded Rules:**

- `PSAvoidUsingWriteHost` - Handled separately in basic checks (context-aware)

## Common Rules Enforced

### Critical Rules (Error Severity)

| Rule | Description | Example Fix |
| ---- | ----------- | ----------- |
| PSUseDeclaredVarsMoreThanAssignments | Variable assigned but never used | Remove unused variables |
| PSPossibleIncorrectUsageOfAssignmentOperator | Using `=` instead of `-eq` in conditionals | Use `-eq` for comparison |
| PSMissingModuleManifestField | Required manifest fields missing | Add required fields to .psd1 |
| PSUseToExportFieldsInManifest | Use explicit exports in manifests | Specify FunctionsToExport explicitly |

### Best Practice Rules (Warning Severity)

| Rule | Description | Example Fix |
| ---- | ----------- | ----------- |
| PSAvoidUsingCmdletAliases | Cmdlet aliases used (e.g., `gci`) | Use `Get-ChildItem` instead |
| PSAvoidUsingPositionalParameters | Positional parameters used | Use `-Path $value` instead of `$value` |
| PSUseShouldProcessForStateChangingFunctions | ShouldProcess missing from state-changing functions | Add `SupportsShouldProcess=$true` |
| PSProvideCommentHelp | Missing comment-based help | Add synopsis, description, examples |
| PSUseBOMForUnicodeEncodedFile | BOM missing from Unicode files | Save with UTF-8 with BOM |

## AgentGov-Specific Configuration

### Standards Alignment

PSScriptAnalyzer checks align with [PowerShell Standards](.github/instructions/powershell.instructions.md):

| Standard | PSScriptAnalyzer Rule | Status |
| -------- | -------------------- | ------ |
| Full cmdlet names | PSAvoidUsingCmdletAliases | [COMPLETE] Enforced |
| Explicit parameters | PSAvoidUsingPositionalParameters | [COMPLETE] Enforced |
| Approved verbs | PSUseApprovedVerbs | [COMPLETE] Enforced |
| CmdletBinding() | PSUseCmdletCorrectly | [COMPLETE] Enforced |
| Write-Verbose | PSAvoidUsingWriteHost | [WARNING] Custom check |

### Output Format

Validation failures show detailed information:

```text
PowerShell validation failed:
  - PSScriptAnalyzer issues detected:
  - [Warning] Line 15 (PSAvoidUsingCmdletAliases): 'gci' is an alias of 'Get-ChildItem'. Alias can introduce possible problems and make scripts hard to maintain. Please consider changing alias to its full content.
  - [Error] Line 23 (PSUseDeclaredVarsMoreThanAssignments): The variable 'unused' is assigned but never used.

PowerShell standards require:
  - Line endings: LF (default) or CRLF with REQUIRES-CRLF marker
  - Encoding: UTF-8 without BOM
  - Use Write-Verbose instead of Write-Host
  - Use explicit parameter names (-Path, -Filter, etc.)
  - Use Join-Path for path construction
```

## Testing PSScriptAnalyzer Integration

### Test 1: Verify Installation

```bash
.github/scripts/validate-powershell.sh .github/scripts/test-sample.ps1
```

**Expected output:**

```text
PowerShell validation passed (PSScriptAnalyzer): .github/scripts/test-sample.ps1
```

### Test 2: Test With Issues

Create a file with violations:

```powershell
# bad-example.ps1
function DoSomething($path) {  # Missing CmdletBinding, positional param
    gci $path                   # Using alias, unquoted variable
    Write-Host "Done"           # Using Write-Host
}
```

Run validator:

```bash
.github/scripts/validate-powershell.sh bad-example.ps1
```

**Expected:** Multiple PSScriptAnalyzer issues detected

### Test 3: Without PSScriptAnalyzer

Temporarily uninstall or rename the module to test fallback:

```bash
# This will show a message about installing PSScriptAnalyzer
.github/scripts/validate-powershell.sh script.ps1
```

## Suppressing Rules (When Justified)

If a rule violation is justified, you can suppress it:

### Inline Suppression

```powershell
# Suppress specific rule for next line
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param()

Write-Host "This is for interactive user display only"
```

### Function-Level Suppression

```powershell
function Get-InteractiveInput {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    [CmdletBinding()]
    param()
    
    Write-Host "Enter your choice: " -NoNewline
    return Read-Host
}
```

### Script-Level Suppression

```powershell
# At top of script
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
param()
```

**Important:** Only suppress rules when there's a valid technical reason. Document why in comments.

## Customizing PSScriptAnalyzer Rules

To customize rules for the entire project, create a settings file:

```powershell
# .github/config/PSScriptAnalyzerSettings.psd1
@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'  # Handled by custom check
    )
    IncludeDefaultRules = $true
}
```

Update validator to use custom settings:

```bash
# In validate-powershell.sh, change:
Invoke-ScriptAnalyzer -Path '$file' -Severity Error,Warning -ExcludeRule PSAvoidUsingWriteHost

# To:
Invoke-ScriptAnalyzer -Path '$file' -Settings '.github/config/PSScriptAnalyzerSettings.psd1'
```

## Troubleshooting

### Issue: PSScriptAnalyzer Not Found

**Symptom:**

```text
PowerShell validation failed:
  - CRITICAL: PSScriptAnalyzer module is not installed
  - PowerShell files REQUIRE PSScriptAnalyzer for comprehensive validation
  - Install: pwsh -Command "Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force"

PowerShell standards require:
  - PSScriptAnalyzer must be installed (comprehensive validation REQUIRED)
```

**Solution:**

```bash
pwsh -Command "Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force"
```

**Important:** As of this implementation, PSScriptAnalyzer is **mandatory** for PowerShell file validation. The validator will **fail** if PSScriptAnalyzer is not installed, preventing silent continuation with only basic checks.

### Issue: Permission Denied Installing Module

**Solution:** Use `-Scope CurrentUser` instead of default AllUsers:

```bash
pwsh -Command "Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force"
```

### Issue: False Positives

**Solution:** Suppress specific rules with `[Diagnostics.CodeAnalysis.SuppressMessageAttribute()]` and document why.

### Issue: Slow Analysis

**Solution:** PSScriptAnalyzer can be slow on large files. Consider:

- Breaking large scripts into modules
- Increasing hook timeout in [quality-validation.json](.github/hooks/quality-validation.json):

```json
{
  "hooks": {
    "PostToolUse": [{
      "timeout": 60
    }]
  }
}
```

## Resources

- **PSScriptAnalyzer GitHub:** <https://github.com/PowerShell/PSScriptAnalyzer>
- **PSScriptAnalyzer Rules:** <https://github.com/PowerShell/PSScriptAnalyzer/tree/master/docs/Rules>
- **AgentGov PowerShell Standards:** [.github/instructions/powershell.instructions.md](.github/instructions/powershell.instructions.md)
- **Quality Validation System:** [.github/hooks/README.md](.github/hooks/README.md)

## Status

- [COMPLETE] PSScriptAnalyzer integrated in validate-powershell.sh
- [COMPLETE] Automatic detection and execution
- [COMPLETE] Error and Warning severity levels enforced
- [COMPLETE] Formatted output with line numbers and rule names
- [COMPLETE] Graceful fallback when not installed
- [COMPLETE] Installation guidance in failure messages
- [COMPLETE] Test script created and verified ([test-sample.ps1](.github/scripts/test-sample.ps1))

---

**Last Updated:** February 18, 2026
