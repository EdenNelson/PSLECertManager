# PSLECertManager Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to date-based versioning (YYYY.M.D).

## [2026.1.20] - 2026-01-20

### Added (2026.1.20)

- Dynamic Posh-ACME version detection (auto-detects latest version in Posh-ACME/ directory)
- Log rotation with 1MB cap per file, 5 rotation files, 90-day retention
- PostScripts/ directory for organized post-action script management
- VERSION file and CHANGELOG.md for project versioning
- macOS system files (.DS_Store) and wildcard Secret pattern to .gitignore
- AI context awareness rules to coding standards

### Changed (2026.1.20)

- Reorganized post-action scripts into PostScripts/ directory (Set-ADFSCert.ps1, Set-WAPCert.ps1, Set-CMCMGCert.ps1)
- Updated all scripts to use begin/process/end blocks for proper structure
- Converted all scripts to use tabs for indentation (Standard 10)
- Updated all scripts to use Join-Path for path construction (Standard 3)
- Logging setup moved into begin block for all scripts (Standard 8)
- Updated logging to use dynamic script names via $MyInvocation.MyCommand.Name
- Modularized Update-Certificate.ps1 with helper functions (Initialize-Variables, Initialize-Secrets, Initialize-PoshAcmeModule, Set-AcmeServer, Get-CertificateUpdateNeeded, New-AcmeCertificate, Invoke-PostScript)

### Fixed (2026.1.20)

- Removed duplicate post-action deployment code in Update-Certificate.ps1
- Fixed variable reference parsing issue with $MainDomain in error messages

### Security (2026.1.20)

- Enhanced .gitignore to catch all files with "Secret" in their names

## [2026.1.22] - 2026-01-22

### Added

- Added support for reading version information from `VERSION.md` for better documentation.
- Implemented automated version validation in `Update-Certificate.ps1` to ensure consistency between `VERSION.md` and the scripts.
- Introduced `Test-Script.ps1` for automated testing of post-action scripts.

### Changed

- Refactored `Initialize-Variables` to include version validation logic.
- Updated `Set-ADFSCert.ps1`, `Set-WAPCert.ps1`, and `Set-CMCMGCert.ps1` to include additional logging for debugging.
- Improved error handling in `Update-Certificate.ps1` for better diagnostics.

### Fixed

- Corrected a bug where `Join-Path` was not resolving relative paths correctly in `PostScripts/Set-WAPCert.ps1`.
- Fixed an issue with log rotation not triggering correctly when the log file exceeded 1MB.

### Security

- Hardened `Initialize-Secrets` to prevent accidental exposure of sensitive data in debug logs.

## [2026.7.14] - 2026-07-14

### Added

- `PostScripts/Set-IISCert.ps1` post-action script: binds the issued certificate to IIS HTTPS
  bindings via http.sys (no IIS restart required). Supports staging validation-only mode and an
  optional, self-discovered `Set-IISCert` configuration subobject in `Vars.psd1`
  (`Sites`, `Port`, `StoreName`, `CreateBindingIfMissing`, `HostHeader`, `IPAddress`, `RequireSNI`).
  When no config is supplied, it rebinds all existing HTTPS bindings on the server.

### Changed

- Documented the IIS post-script in `README.md`, `PROJECT_CONTEXT.md`, and `Vars.psd1.example`.


## [2026.8.19] - 2026-08-19

### Fixed

- Fixed `Get-CachedCredentials` in `Update-Certificate.ps1` incorrectly demanding fresh `BitWardenSecrets.psd1` credentials whenever Posh-ACME's `cert.cer` file was missing from the cache, even when the PA account, order, and cached Route53 plugin args (`pluginargs.json`) were still present and valid (e.g. after `cert.cer`/`cert.pfx`/etc. were externally removed by AV/EDR or backup software). The script now recovers using the cached Route53 credentials from the existing order instead of failing.
- Fixed a `$CleanupReason:` variable-reference parsing bug in `Remove-StaleSecretFiles` (same class of issue as the `$MainDomain` fix in 2026.1.20) that caused the entire script to fail to parse.
- Fixed `Get-CachedCredentials` reporting "Cache validation PASSED" for a full PA Account + Certificate + Order hit even when the order's cached Route53 plugin args or account contact email were empty (e.g. right after the Posh-ACME account/cache was recreated following an API key rotation). The script now verifies the cached credentials are actually complete before trusting them, falling back to BitWarden otherwise.
- Fixed `Initialize-Secrets` silently proceeding with empty cached credentials instead of validating them like the existing BitWarden path already did. An incomplete cache previously reached `New-AcmeCertificate` with an empty `$Email`, which PowerShell rejects as a non-terminating parameter-binding error - so the script logged no `[ERROR]` and simply skipped issuance while reporting a normal completion. This is now a loud, logged failure.
- Added a hard invariant at the end of `Update-Certificate.ps1`: if a certificate was ever determined to be needed, the run can no longer exit through the quiet "No certificate update needed" branch without one actually being installed - it now logs an `[ERROR]` and throws instead, as a backstop against any future silent no-op path.
- Fixed `BitWardenSecrets.psd1` being ignored (and then deleted by stale-file cleanup) whenever the Posh-ACME cache looked structurally complete, even if the cached Route53 credentials were actually stale (e.g. after a key rotation that cache validation can't detect, since it only checks presence, not validity). A present `BitWardenSecrets.psd1` is now treated as an explicit operator override to pull the current secret from BitWarden instead of trusting the cache.