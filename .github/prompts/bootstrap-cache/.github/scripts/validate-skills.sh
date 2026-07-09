#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

skill_dir=".github/skills"
if [[ ! -d "$skill_dir" ]]; then
  printf '%s\n' "Skills directory not found: ${skill_dir}" >&2
  exit 1
fi

# Use a temp file to collect SKILL.md files (portable across bash/zsh)
temp_file=$(mktemp)
trap "rm -f '$temp_file'" EXIT

find "$skill_dir" -type f -name 'SKILL.md' | sort > "$temp_file"
if [[ ! -s "$temp_file" ]]; then
  printf '%s\n' "No SKILL.md files found under ${skill_dir}" >&2
  exit 1
fi

while IFS= read -r file; do
  first_line=$(head -n 1 "$file")
  if [[ "$first_line" != "---" ]]; then
    printf '%s\n' "Missing YAML frontmatter start in ${file}" >&2
    exit 1
  fi

  end_line=$(awk 'NR>1 && $0=="---" {print NR; exit 0}' "$file" || true)
  if [[ -z "${end_line:-}" ]]; then
    printf '%s\n' "Missing YAML frontmatter end in ${file}" >&2
    exit 1
  fi

  name_present=$(awk 'NR>1 && $0=="---" {exit} $0 ~ /^name:[[:space:]]*/ {found=1} END {if (found) print "yes"}' "$file")
  desc_present=$(awk 'NR>1 && $0=="---" {exit} $0 ~ /^description:[[:space:]]*/ {found=1} END {if (found) print "yes"}' "$file")
  if [[ "$name_present" != "yes" || "$desc_present" != "yes" ]]; then
    printf '%s\n' "Missing name or description in frontmatter for ${file}" >&2
    exit 1
  fi
done < "$temp_file"

printf '%s\n' "Skills frontmatter validation passed."
