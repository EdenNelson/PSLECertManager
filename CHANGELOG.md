# Changelog

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
