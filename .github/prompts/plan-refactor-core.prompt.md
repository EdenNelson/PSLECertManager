# Refactor Plan for PSLECertManager

Last updated: 2026-01-23
Author: GitHub Copilot (GPT-5.1-Codex-Max)

## Goals

- Improve maintainability, testability, and idempotence of certificate automation.
- Standardize logging, error handling, and config/secrets flows across scripts.
- Reduce duplication in post-action scripts and scheduled task setup.
- Harden security around secrets and file operations.
- Add automated validation (Pester) and clearer documentation.

## Phased Plan

1. Foundations & Shared Utilities (Local Bundled Module)

- Create **local bundled module** `Modules/PSLE.Utils/PSLE.Utils.psm1` for logging (rotating, verbose-first), path helpers, config loading (Vars.psd1), secret file IO (atomic write), certificate lookup, and common error helpers.
  - This is **NOT an external dependency**; the module ships with the project in the `Modules/` folder.
  - PowerShell auto-discovers local modules in `$PSScriptRoot/Modules/`; no user manual import needed.
  - End-user experience unchanged: copy folder, run `Register-CertificateScheduledTask.ps1`, done.
- Normalize `-ErrorAction Stop` + `try/catch` + `throw`; remove `exit` in library code.
- Remove duplicated signature blocks when files are edited (re-sign later if required).

1. Update-Certificate.ps1 Decomposition

- Split into clear functions (Get-Configuration, Initialize-Logging, Import-PoshAcme, Resolve-CachedCredentials, Ensure-Secrets, Ensure-AcmeServer, Assess-CertificateState, Request-Certificate, Invoke-PostAction, Main).
- Use region-based phases for clarity; emit structured status objects for callers.
- Harden Posh-ACME import/version detection and cache validation.

1. Secret Handling Hardening (Invoke-SecretFile.ps1)

- Use bws with retry/backoff, strict JSON validation, and atomic `Secret.psd1` writes.
- Standardize secure-string handling; avoid global variable leakage; better required-key validation.

1. Task Registration Improvements

- Make `Register-CertificateScheduledTask.ps1` idempotent: detect drift, update when needed, validate script/PowerShell paths and PostScript presence.
- Add dry-run and richer verbose/audit output.

1. Post-Script Consolidation (ADFS/WAP/CMCMG/NPS)

- Share logging/staging/cert lookup helpers; each script focuses on its domain action.
- Replace `exit` with `throw`/`Write-Error`; add role presence prechecks and clearer guidance when missing.

1. Testing & CI

- Add Pester tests for config parsing, Posh-ACME version detection, secret generation (mocked bws), scheduled task args, and post-script parameter contracts/staging behavior.
- Integrate PSScriptAnalyzer and test runs into CI (GitHub Actions or AzDO).

1. Documentation & Ops

- Update README/PROJECT_CONTEXT with new module layout, logging behavior, new switches (dry-run, keep-secrets), and troubleshooting matrix.
- Ensure file writes use UTF8 (no BOM) and atomic replace; document log retention and cleanup guidance.
- Provide non-sensitive summary/telemetry outputs for monitoring.

## End-User Impact

**The refactoring maintains project simplicity:**

- Users continue to copy the entire project folder to their Windows Server.
- Users run `Register-CertificateScheduledTask.ps1` as usual; no changes to entry point or workflow.
- The internal `Modules/` folder is transparent to users—PowerShell handles module discovery automatically.
- No external dependencies are introduced; everything remains self-contained.

## Open Decisions

- Re-sign scripts after refactor vs. keep unsigned during development.
- Prioritize which post-script(s) to refactor first based on current deployment targets.
- CI platform choice (GitHub Actions vs. AzDO) and Pester/PSScriptAnalyzer coverage depth.
