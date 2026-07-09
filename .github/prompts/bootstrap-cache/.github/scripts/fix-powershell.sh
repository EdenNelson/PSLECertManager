#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# PowerShell fixer: auto-corrects common PowerShell issues
# Purpose: Clean up files automatically before validation
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

# Fix 1: Ensure file uses LF line endings (unless marked REQUIRES-CRLF)
if grep -q 'REQUIRES-CRLF' "$file" 2>/dev/null; then
  # File requires CRLF; convert from LF if needed
  if ! file "$file" | grep -q 'CRLF'; then
    unix2dos "$file" 2>/dev/null || {
      # Fallback: use sed to add CR before LF
      sed -i '' 's/$//' "$file"
    }
  fi
else
  # File should use LF; convert from CRLF if needed
  if file "$file" | grep -q 'CRLF'; then
    dos2unix "$file" 2>/dev/null || {
      # Fallback: use sed to remove CR characters
      sed -i '' 's/$//' "$file"
    }
  fi
fi

# Fix 2: Replace em dash with ASCII hyphen per ADR-0014 & powershell.instructions.md
# Em dash (U+2014) forbidden; must use ASCII hyphen (U+002D)
# Handle all Unicode em dash variations
sed -i '' 's/—/-/g' "$file"
sed -i '' 's/–/-/g' "$file"

# Fix 3: Ensure file ends with exactly one newline
if [[ -n "$(tail -c 1 "$file")" ]]; then
  printf '\n' >> "$file"
fi

# Fix 4: Remove trailing whitespace from all lines
sed -i '' 's/[[:space:]]*$//' "$file"

# Success
exit 0
