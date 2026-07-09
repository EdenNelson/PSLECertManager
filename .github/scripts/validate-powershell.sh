#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# PowerShell syntax validator: checks parse errors, line endings, encoding, and balanced elements
# Purpose: Validate that scripts will parse without errors (syntax), not code style/best practices
# Args: $1 = file path

if [[ $# -lt 1 ]]; then
  printf 'Usage: %s <powershell-file>\n' "$0" >&2
  exit 1
fi

file="$1"

if [[ ! -f "$file" ]]; then
  printf 'File not found: %s\n' "$file" >&2
  exit 1
fi

errors=()

# Check 1: Line endings should be LF by default (unless REQUIRES-CRLF marker present)
if grep -q 'REQUIRES-CRLF' "$file"; then
  # CRLF is required for this file
  if ! file "$file" | grep -q 'CRLF'; then
    errors+=("File marked REQUIRES-CRLF but uses LF line endings")
  fi
else
  # LF is required (default)
  if file "$file" | grep -q 'CRLF'; then
    errors+=("File uses CRLF line endings (should use LF unless marked REQUIRES-CRLF)")
  fi
fi

# Check 2: Should be UTF-8 encoded
if ! file -b --mime-encoding "$file" | grep -qE 'utf-8|us-ascii'; then
  errors+=("File encoding is not UTF-8")
fi

# Check 3: Require two blank lines between code and signature block (or EOF)
blank_line_check=$(awk '
  BEGIN { last_code_line = 0; sig_start = 0 }
  /^# SIG # Begin signature block$/ { sig_start = NR; next }
  /^[[:space:]]*$/ { next }
  { last_code_line = NR }
  END {
    if (last_code_line == 0) {
      print "no_code"
      exit 0
    }
    if (sig_start > 0) {
      blank_gap = sig_start - last_code_line - 1
      if (blank_gap != 2) {
        print "sig_blank_mismatch:" blank_gap
      } else {
        print "ok"
      }
    } else {
      blank_gap = NR - last_code_line
      if (blank_gap != 2) {
        print "eof_blank_mismatch:" blank_gap
      } else {
        print "ok"
      }
    }
  }
' "$file")

if [[ "$blank_line_check" == "no_code" ]]; then
  errors+=("File has no code")
elif [[ "$blank_line_check" != "ok" ]]; then
  errors+=("$blank_line_check")
fi

# Check 4: Balanced syntax elements (excluding comments)
content=$(grep -v '^\s*#' "$file" || true)

# Count braces
open_braces=$(echo "$content" | tr -cd '{' | wc -c | tr -d ' ')
close_braces=$(echo "$content" | tr -cd '}' | wc -c | tr -d ' ')
if [[ "$open_braces" -ne "$close_braces" ]]; then
  errors+=("Unbalanced braces: $open_braces opening '{' vs $close_braces closing '}'")
fi

# Count brackets
open_brackets=$(echo "$content" | tr -cd '[' | wc -c | tr -d ' ')
close_brackets=$(echo "$content" | tr -cd ']' | wc -c | tr -d ' ')
if [[ "$open_brackets" -ne "$close_brackets" ]]; then
  errors+=("Unbalanced brackets: $open_brackets opening '[' vs $close_brackets closing ']'")
fi

# Count parentheses
open_parens=$(echo "$content" | tr -cd '(' | wc -c | tr -d ' ')
close_parens=$(echo "$content" | tr -cd ')' | wc -c | tr -d ' ')
if [[ "$open_parens" -ne "$close_parens" ]]; then
  errors+=("Unbalanced parentheses: $open_parens opening '(' vs $close_parens closing ')'")
fi

# Check 5: CRITICAL - PSScriptAnalyzer validation (syntax errors only)
pssa_available=false
pssa_used=false

if ! command -v pwsh &>/dev/null; then
  errors+=("CRITICAL: PowerShell (pwsh) is not installed")
  errors+=("Install: brew install powershell")
elif ! pwsh -NoProfile -Command "Get-Module -ListAvailable -Name PSScriptAnalyzer" &>/dev/null; then
  errors+=("CRITICAL: PSScriptAnalyzer module is not installed")
  errors+=("PowerShell syntax validation requires PSScriptAnalyzer for parse error detection")
  errors+=("Install: pwsh -Command \"Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force\"")
else
  pssa_available=true
  pssa_used=true
  
  # Run PSScriptAnalyzer for syntax/parse errors only (Error severity)
  ps_validation=$(pwsh -NoProfile -Command "
    Import-Module PSScriptAnalyzer -ErrorAction Stop
    \$results = Invoke-ScriptAnalyzer -Path '$file' -Severity Error
    if (\$results) {
      \$results | ForEach-Object {
        \$severity = \$_.Severity
        \$line = \$_.Line
        \$rule = \$_.RuleName
        \$message = \$_.Message
        Write-Output \"[\$severity] Line \$line (\$rule): \$message\"
      }
      exit 1
    } else {
      exit 0
    }
  " 2>&1) || {
    errors+=("PSScriptAnalyzer syntax errors detected:")
    errors+=("$ps_validation")
  }
fi

# Report errors
if [[ ${#errors[@]} -gt 0 ]]; then
  printf 'PowerShell validation failed:\n' >&2
  for err in "${errors[@]}"; do
    printf '  %s\n' "$err" >&2
  done
  printf '\nPowerShell syntax validation checks:\n' >&2
  printf '  - Line endings: LF (default) or CRLF with REQUIRES-CRLF marker\n' >&2
  printf '  - Encoding: UTF-8 (with or without BOM)\n' >&2
  printf '  - Balanced syntax elements: {}, [], ()\n' >&2
  printf '  - PSScriptAnalyzer parse errors (Error severity only)\n' >&2
  printf '\nNote: This validator checks syntax/parse errors only, not style rules.\n' >&2
  exit 1
fi

# Success: Syntax validation passed
printf 'PowerShell syntax validation passed: %s\n' "$file"
exit 0
