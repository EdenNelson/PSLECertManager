#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Markdown validator: checks CommonMark spec compliance
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

# Check if markdownlint-cli is available
if command -v markdownlint &>/dev/null; then
  # Use markdownlint with CommonMark rules
  # Focus on: MD031 (blank lines around fenced code), MD032 (blank lines around lists),
  # MD036 (emphasis used instead of heading), MD040 (fenced code language)
  markdownlint --config .github/config/markdownlint.json "$file" || {
    printf 'CommonMark compliance check failed. Key issues to fix:\n' >&2
    printf '  - MD031: Blank line required before/after fenced code blocks\n' >&2
    printf '  - MD032: Blank line required before/after lists\n' >&2
    printf '  - MD036: Do not use emphasis for headings (use # syntax)\n' >&2
    printf '  - MD040: Specify language for fenced code blocks\n' >&2
    exit 1
  }
else
  # Fallback: basic validation without markdownlint
  errors=()
  
  # Check 1: File must end with newline
  if [[ -n "$(tail -c 1 "$file")" ]]; then
    errors+=("Missing final newline at end of file")
  fi
  
  # Check 2: NO emojis allowed (strict enforcement)
  # Check for specific common emojis using literal characters
  if grep -q '[✅⏳❌⚠️🛑🔍📝💡]' "$file" 2>/dev/null; then
    errors+=("EMOJI DETECTED: Emojis are strictly prohibited in all markdown files")
    errors+=("  Use text equivalents: [COMPLETE] [PENDING] [REJECTED] [WARNING] [CRITICAL]")
    errors+=("  Rationale: Emojis consume 3-4x more tokens than text equivalents")
  fi
  
  # Check 3: Fenced code blocks should have language tags
  if grep -Pzo '```\n(?!```)' "$file" 2>/dev/null | grep -q '```'; then
    errors+=("Fenced code blocks missing language specifier (e.g., \`\`\`bash)")
  fi
  
  # Report errors
  if [[ ${#errors[@]} -gt 0 ]]; then
    printf 'Markdown validation failed:\n' >&2
    for err in "${errors[@]}"; do
      printf '  - %s\n' "$err" >&2
    done
    printf '\nCommonMark requirements:\n' >&2
    printf '  - Blank line before/after headings and lists\n' >&2
    printf '  - Language specified for fenced code blocks\n' >&2
    printf '  - Final newline at end of file\n' >&2
    printf '  - NO EMOJIS ALLOWED (strict enforcement)\n' >&2
    printf '  - Use text equivalents: [COMPLETE] [PENDING] [WARNING] [CRITICAL]\n' >&2
    printf '\nSee: .github/instructions/markdown.instructions.md for full standards\n' >&2
    exit 1
  fi
fi

printf 'Markdown validation passed: %s\n' "$file"
exit 0
