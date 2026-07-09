---
name: 'Bash Standards'
description: 'Strict coding standards for Bash shell automation'
applyTo: '**/*.sh'
---
# AI CODING STANDARDS: BASH (STRICT)

**SCOPE:** Applies to *.sh files and shell automation.

## 1. BASH STANDARDS

### 1.1 The "Safety Net" Header

Every Bash script MUST start with strict mode directives:

```bash
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
```

**Rationale:** Bash (4.x or later) is the standard for shell automation in this framework. These directives are mandatory because:

- `set -e`: Exit on any error, preventing silent failures
- `set -u`: Fail on undefined variables, catching typos and uninitialized vars
- `set -o pipefail`: Catch errors in piped commands, not just the final command
- `IFS=$'\n\t'`: Restrict word splitting to newlines and tabs, preventing word-splitting bugs

This trades portability (POSIX sh compatibility) for safety and clarity. All shell automation in AgentGov targets Bash 4.x or later, available on macOS, Linux, and Windows (WSL, Git Bash, Cygwin).

### 1.2 Logic & Syntax

- **Expansion:** Always quote variables (`"${VAR}"`) and use curly braces (`"${FILE_PATH}"`).
- **Conditionals:** Prefer `[[ ... ]]` over `[ ... ]`.
- **Output:** Use `printf` instead of `echo` for portability.

### 1.3 Cleanup

Use `trap` to ensure temporary artifacts are removed on EXIT.
