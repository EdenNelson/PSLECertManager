Plan: PowerShell standards fixes for PSLECertManager

Goals
- Align scripts with AI/PowerShell standards; avoid touching existing signature blocks.

Tasks
1) Replace status Write-Output with Write-Verbose or Write-Log (no pipeline objects intended).
2) Add explicit parameters: -Process for ForEach-Object, -FilterScript for Where-Object, -Path for Test-Path.
3) Ensure Write-Error uses -Message in logging helpers.
4) Improve comment-based help: real PARAMETER descriptions for BitWardenSecretsFilePath, SecretFilePath, DeleteSecretFile, etc.
5) Normalize indentation to 4 spaces per standards (avoid tabs).

Notes
- Do not modify existing signature blocks.
- Keep existing logging pattern (Write-Log + Write-Verbose).