#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Hook dispatcher: routes file fixes to appropriate fixers
# Receives PostToolUse hook input via stdin, auto-fixes common issues before validation

# Read hook input from stdin
input=$(cat)

# Extract tool name and file paths from hook input
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
tool_input=$(printf '%s' "$input" | jq -r '.tool_input // {}')

# Only fix file edit operations
if [[ "$tool_name" != "replace_string_in_file" && 
      "$tool_name" != "create_file" && 
      "$tool_name" != "multi_replace_string_in_file" &&
      "$tool_name" != "edit_notebook_file" ]]; then
  # Not a file edit operation; skip fixes
  printf '{"continue": true}\n'
  exit 0
fi

# Extract file paths from tool input
files=()
if [[ "$tool_name" == "multi_replace_string_in_file" ]]; then
  # Multiple files in replacements array
  while IFS= read -r file; do
    if [[ -n "$file" ]]; then
      files+=("$file")
    fi
  done < <(printf '%s' "$tool_input" | jq -r '.replacements[]?.filePath // empty' | sort -u)
else
  # Single file
  file=$(printf '%s' "$tool_input" | jq -r '.filePath // empty')
  if [[ -n "$file" ]]; then
    files=("$file")
  fi
fi

# If no files extracted, nothing to fix
if [[ ${#files[@]} -eq 0 ]]; then
  printf '{"continue": true}\n'
  exit 0
fi

# Apply fixes to each file
for file in "${files[@]}"; do
  # Skip if file doesn't exist
  if [[ ! -f "$file" ]]; then
    continue
  fi
  
  # Determine file type and fixer
  fixer=""
  case "$file" in
    *.md)
      fixer=".github/scripts/fix-markdown.sh"
      ;;
    *.sh)
      fixer=".github/scripts/fix-bash.sh"
      ;;
    *.ps1|*.psm1|*.psd1)
      fixer=".github/scripts/fix-powershell.sh"
      ;;
    *)
      # No fixer for this file type
      continue
      ;;
  esac
  
  # Run fixer if it exists
  if [[ -x "$fixer" ]]; then
    "$fixer" "$file" || {
      # Log fixer warnings but don't fail; validation will catch real errors
      printf 'Warning: fixer encountered issue with %s\n' "$file" >&2
    }
  fi
done

# Allow execution to continue
printf '{"continue": true}\n'
exit 0
