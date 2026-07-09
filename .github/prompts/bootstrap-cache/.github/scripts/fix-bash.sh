#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Bash fixer: auto-corrects bash boilerplate requirements
# Purpose: Ensure shebang, set -euo pipefail, and IFS declaration
# Args: $1 = file path

if [[ $# -lt 1 ]]; then
  printf 'Usage: %s <bash-file>\n' "$0" >&2
  exit 1
fi

file="$1"

if [[ ! -f "$file" ]]; then
  printf 'File not found: %s\n' "$file" >&2
  exit 1
fi

# Create temp file to reconstruct with correct boilerplate
temp_file="${file}.tmp.$$"

{
  # Always ensure correct shebang on line 1
  printf '#!/bin/bash\n'
  
  # Always ensure set -euo pipefail on line 2
  printf 'set -euo pipefail\n'
  
  # Always ensure IFS declaration on line 3
  printf 'IFS=$'"'"'\\n\\t'"'"'\n'
  
  # Append rest of file (skip first 3 lines to avoid duplication)
  # Use tail with 2>/dev/null to handle files with < 3 lines gracefully
  tail -n +4 "$file" 2>/dev/null || true
} > "$temp_file"

# Replace original file with fixed version
mv "$temp_file" "$file"

# Fix: Ensure trailing newline
if [[ -n "$(tail -c 1 "$file")" ]]; then
  printf '\n' >> "$file"
fi

# Fix: Remove trailing whitespace from all lines
sed -i '' 's/[[:space:]]*$//' "$file"

exit 0
