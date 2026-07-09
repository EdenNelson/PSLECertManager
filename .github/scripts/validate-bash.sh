#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Bash validator: checks strict mode compliance and best practices
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

errors=()

# Check 1: Shebang must be #!/bin/bash
shebang=$(head -n 1 "$file")
if [[ "$shebang" != "#!/bin/bash" ]]; then
  errors+=("Missing or incorrect shebang (required: #!/bin/bash)")
fi

# Check 2: Must have strict mode (set -euo pipefail)
if ! grep -q '^set -euo pipefail' "$file"; then
  errors+=("Missing strict mode: set -euo pipefail")
fi

# Check 3: Must set IFS
if ! grep -q '^IFS=' "$file"; then
  errors+=("Missing IFS declaration: IFS=\$'\\n\\t'")
fi

# Check if shellcheck is available for deeper analysis
if command -v shellcheck &>/dev/null; then
  if ! shellcheck_output=$(shellcheck -s bash -x "$file" 2>&1); then
    errors+=("ShellCheck issues detected:")
    errors+=("$shellcheck_output")
  fi
fi

# Report errors
if [[ ${#errors[@]} -gt 0 ]]; then
  printf 'Bash validation failed:\n' >&2
  for err in "${errors[@]}"; do
    printf '  - %s\n' "$err" >&2
  done
  printf '\nBash standards require:\n' >&2
  printf '  - Shebang: #!/bin/bash\n' >&2
  printf '  - Strict mode: set -euo pipefail\n' >&2
  printf '  - IFS declaration: IFS=$'"'"'\\n\\t'"'"'\n' >&2
  printf '  - Quote variables: "\${VAR}"\n' >&2
  printf '  - Use [[ ]] for conditionals\n' >&2
  printf '  - Use printf instead of echo\n' >&2
  exit 1
fi

# Success message
if command -v shellcheck &>/dev/null; then
  printf 'Bash validation passed (shellcheck): %s\n' "$file"
else
  printf 'Bash validation passed (basic checks): %s\n' "$file"
  printf 'Note: Install shellcheck for comprehensive validation\n'
fi
exit 0
