#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Hook dispatcher: routes file validation to appropriate validators
# Receives PostToolUse hook input via stdin, validates edited files

# Read hook input from stdin
input=$(cat)

# Extract tool name and file paths from hook input
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
tool_input=$(printf '%s' "$input" | jq -r '.tool_input // {}')

# Only validate file edit operations
if [[ "$tool_name" != "replace_string_in_file" &&
      "$tool_name" != "create_file" &&
      "$tool_name" != "multi_replace_string_in_file" &&
      "$tool_name" != "edit_notebook_file" ]]; then
  # Not a file edit operation; skip validation
  printf '{"continue": true}\n'
  exit 0
fi

# Extract file paths from tool input
files=()
if [[ "$tool_name" == "multi_replace_string_in_file" ]]; then
  # Multiple files in replacements array (portable alternative to mapfile)
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

# If no files extracted, nothing to validate
if [[ ${#files[@]} -eq 0 ]]; then
  printf '{"continue": true}\n'
  exit 0
fi

# Validation results
all_passed=true
validation_messages=()

# Validate each file
for file in "${files[@]}"; do
  # Skip if file doesn't exist (might be deleted)
  if [[ ! -f "$file" ]]; then
    continue
  fi

  # Determine file type and validator
  validator=""
  case "$file" in
    .github/skills/*/SKILL.md)
      validator=".github/scripts/validate-skills.sh"
      ;;
    *.md)
      validator=".github/scripts/validate-markdown.sh"
      ;;
    *.sh)
      validator=".github/scripts/validate-bash.sh"
      ;;
    *.ps1|*.psm1|*.psd1)
      validator=".github/scripts/validate-powershell.sh"
      ;;
    *)
      # No validator for this file type
      continue
      ;;
  esac

  # Run validator if it exists
  if [[ -x "$validator" ]]; then
    if ! validation_output=$("$validator" "$file" 2>&1); then
      all_passed=false
      validation_messages+=("$(basename "$file"): validation failed")
      validation_messages+=("$validation_output")
    fi
  fi
done

# Return hook response
if [[ "$all_passed" == "true" ]]; then
  printf '{"continue": true}\n'
  exit 0
else
  # Validation failed; inject context for agent to fix
  message=$(printf '%s\n' "${validation_messages[@]}" | jq -Rs .)
  printf '{\n'
  printf '  "hookSpecificOutput": {\n'
  printf '    "hookEventName": "PostToolUse",\n'
  printf '    "additionalContext": %s\n' "$message"
  printf '  }\n'
  printf '}\n'
  exit 0
fi
