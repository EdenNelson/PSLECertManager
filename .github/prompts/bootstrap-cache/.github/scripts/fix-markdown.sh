#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Markdown fixer: auto-corrects common markdown issues per markdown.instructions.md
# Purpose: Clean up files automatically before validation
# Args: $1 = file path

if [[ $# -lt 1 ]]; then
  printf 'Usage: %s <markdown-file>\n' "$0" >&2
  exit 1
fi

file="$1"

if [[ ! -f "$file" ]]; then
  printf 'File not found: %s\n' "$file" >&2
  exit 1
fi

# Ensure file ends with LF (not CRLF)
if file "$file" | grep -q 'CRLF'; then
  dos2unix "$file" 2>/dev/null || {
    sed -i '' 's/\r$//' "$file"
  }
fi

# Fix 1: Replace prohibited emojis with text equivalents per markdown.instructions.md §2.2
sed -i '' 's/✅/[COMPLETE]/g' "$file"
sed -i '' 's/⏳/[PENDING]/g' "$file"
sed -i '' 's/❌/[REJECTED]/g' "$file"
sed -i '' 's/⚠️/[WARNING]/g' "$file"
sed -i '' 's/🛑/[CRITICAL]/g' "$file"
sed -i '' 's/🔍/[REVIEW]/g' "$file"
sed -i '' 's/📝/[NOTE]/g' "$file"
sed -i '' 's/💡/[TIP]/g' "$file"

# Fix 4: Remove trailing whitespace from all lines
sed -i '' 's/[[:space:]]*$//' "$file"

# Fix 5: Ensure file ends with exactly one newline
if [[ -n "$(tail -c 1 "$file")" ]]; then
  printf '\n' >> "$file"
fi

exit 0
