# PSLECertManager

Certificate Automation with Let's Encrypt and Posh-ACME

**Version**: See [VERSION.md](VERSION.md) and [CHANGELOG.md](CHANGELOG.md)

Automated SSL/TLS certificate lifecycle management using Let's Encrypt, AWS Route53 for DNS-01 validation, and BitWarden for secure credential management. Designed for Windows Server environments with scheduled task automation running as SYSTEM.

## TL;DR - Quick Start

**Set it and forget it in 3 steps:**

1. **Configure your settings**: Copy `Vars.psd1.example` to `Vars.psd1` and set your domain, certificate name, and post-script
2. **Configure BitWarden secrets**: Copy `BitWardenSecrets.psd1.example` to `BitWardenSecrets.psd1` and add your BitWarden API token and secret IDs
3. **Create the scheduled task**: Run `.\Register-CertificateScheduledTask.ps1 -Verbose` as Administrator

**Done!** The scheduled task runs as SYSTEM, The first run starts in 5 minutes from invokation. and then daily at 2 AM requesting and renewing certificates automatically when needed.

## Features

- **Automated Certificate Issuance & Renewal**: Leverages Posh-ACME for Let's Encrypt certificate operations
- **Dynamic Module Version Detection**: Auto-detects latest Posh-ACME version in local directory
- **DNS-01 Validation**: Uses AWS Route53 for domain ownership verification
- **Secure Secret Management**: Integrates BitWarden CLI for credential retrieval
- **Scheduled Automation**: Creates Windows Scheduled Tasks running as NT AUTHORITY\SYSTEM
- **Post-Action Framework**: Extensible post-script execution with self-discovered per-script configuration from Vars.psd1
- **Staging Support**: Test against Let's Encrypt staging environment without hitting rate limits
- **Dual Triggers**: Immediate one-time execution + daily recurring task
- **Configurable Delays**: Randomized execution windows to stagger requests across multiple servers
- **Log Rotation**: Automatic 1MB log cap with 5-file rotation and 90-day retention

## Setup (Intended Use)

### Step 1: Install Prerequisites

1. **Clone or download this repository** to your Windows Server:

   ```powershell
    git clone <repository-url> C:\Scripts\PSLECertManager
    cd C:\Scripts\PSLECertManager
   ```

2. **Install Posh-ACME module**:

   ```powershell
   Install-Module -Name Posh-ACME -Scope CurrentUser -Force
   ```

   Or download a specific version to the local `Posh-ACME/` directory (the script auto-detects the latest local version)

3. **Verify BitWarden CLI is installed**:

   ```powershell
   bws.exe --version
   ```

   If not installed, download from [BitWarden Secrets Manager CLI](https://bitwarden.com/help/secrets-manager-cli/)

4. **Ensure you have AWS Route53** DNS zone hosting the certificate domain(s)

### Step 2: Configure Settings

**Create configuration files** from examples:

```powershell
Copy-Item Vars.psd1.example Vars.psd1
Copy-Item BitWardenSecrets.psd1.example BitWardenSecrets.psd1
```

**Edit Vars.psd1** (Primary Configuration):

```powershell
@{
    # Required: Domain(s) for certificate (comma-separated for SAN certs)
    CertDomains       = "example.cascadetech.org"

    # Required: Friendly name for certificate identification in Windows store
    CertFriendlyName  = "SERVICE Let's Encrypt Certificate"

    # Required: Post-action script to run after certificate operations
    PostScript        = "Set-ADFSCert.ps1"  # Options: Set-ADFSCert.ps1, Set-WAPCert.ps1, Set-CMCMGCert.ps1, Set-NPSCert.ps1

    # Optional: Use staging environment (issues fresh cert every run)
    UseStaging        = $false

    # Optional: Keep secret files after execution (for debugging)
    KeepSecrets       = $false

    # Optional: Random delay for daily task trigger (minutes)
    RandomDelay       = 30

    # Optional: Delay before one-time immediate task execution (minutes)
    InitialDelay      = 5

    # Post-script specific settings are discovered by script basename
    'Set-CMCMGCert' = @{
        Name     = "examplecmg"
        SiteCode = "PRI"
    }

    'Set-NPSCert' = @{
        ServiceName          = "IAS"
        CertHashRegistryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\AuthSvc\Parameters"
    }
}
```

**Configuration Notes:**

- **CertDomains**: Single domain or comma-separated list for Subject Alternative Names
- **PostScript**: Choose the script file in PostScripts/ (for example Set-CMCMGCert.ps1). Script-specific settings are read from the matching Vars.psd1 subobject key (for example Set-CMCMGCert)
- **UseStaging**: Production reuses valid certificates; staging issues new cert every run (for testing)
- **RandomDelay**: Prevents simultaneous execution across multiple servers
- **Self-Discovery Pattern**: Post-scripts read Vars.psd1 using their own basename (without .ps1), so Update-Certificate.ps1 does not need per-script parameter customization

**Edit BitWardenSecrets.psd1** (BitWarden Configuration):

```powershell
@{
    BitWardenSecrets = @{
        BWSToken = "<YOUR_BITWARDEN_API_TOKEN>"
    }
    ScriptSecrets = @{
        Email        = "<BITWARDEN_SECRET_ID_FOR_EMAIL>"
        R53AccessKey = "<BITWARDEN_SECRET_ID_FOR_AWS_ACCESS_KEY>"
        R53SecretKey = "<BITWARDEN_SECRET_ID_FOR_AWS_SECRET_KEY>"
    }
}
```

### Step 3: Create Scheduled Task

Run as **Administrator** to create the automated task:

```powershell
# Create task with defaults from Vars.psd1
.\Register-CertificateScheduledTask.ps1 -Verbose

# Override configuration if needed
.\Register-CertificateScheduledTask.ps1 -MainDomain "example.com" -PostScript "Set-ADFSCert.ps1" -Verbose
```

**That's it!** The scheduled task will:

- Run as **NT AUTHORITY\SYSTEM** (highest privileges)
- Execute once immediately after `InitialDelay` (default 5 minutes)
- Execute daily at 2 AM with `RandomDelay` (default ±30 minutes)
- Automatically renew certificates when they approach expiration

**Scheduled Task Details:**

- **Name**: `Renew-Certificates-{MainDomain}`
- **Path**: `\Cascade Technology Alliance`
- **Principal**: NT AUTHORITY\SYSTEM
- **Triggers**:
  - **One-time**: Runs once after `InitialDelay` (default 5 minutes)
  - **Daily**: Runs at 2 AM with `RandomDelay` (default ±30 minutes)

## Testing & Debugging

### Manual Certificate Issuance (Testing)

Run as **Administrator**:

```powershell
# Production certificate (PostScript from Vars.psd1)
.\Update-Certificate.ps1 -Verbose

# Production certificate with override
.\Update-Certificate.ps1 -PostScript "Set-ADFSCert.ps1" -Verbose

# Staging certificate (testing - fresh cert every run)
.\Update-Certificate.ps1 -UseStaging -Verbose

# Keep secret files on disk for debugging
.\Update-Certificate.ps1 -KeepSecrets -Verbose

# Combine options
.\Update-Certificate.ps1 -PostScript "Set-ADFSCert.ps1" -UseStaging -KeepSecrets -Verbose

# Cleanup-only reset mode (no certificate issuance)
.\Update-Certificate.ps1 -Reset -Verbose
```

**Parameter Priority**: Command-line parameters override `Vars.psd1` values. Missing parameters are read from `Vars.psd1`.

### Reset Mode

Use `-Reset` to remove local automation state and exit without issuance.

Reset mode performs the following cleanup actions:

- Removes Posh-ACME cache folders for the current user and SYSTEM profile
- Removes matching certificates from `Cert:\LocalMachine\My` using `CertFriendlyName`
- Removes the project `Temp` directory (which may contain exported certificate artifacts)
- Removes the scheduled task for the configured main domain

### Staging vs. Production Behavior

| Environment                | Behavior                                                         | Use Case                         |
|----------------------------|------------------------------------------------------------------|----------------------------------|
| **Production** (`LE_PROD`) | Reuses valid certificates; renews only when nearing expiration   | Normal operations                |
| **Staging** (`LE_STAGE`)   | Issues **new certificate every run** regardless of validity      | Testing, validation, development |

**Warning**: Staging certificates are not trusted by browsers. Use only for testing.

### SYSTEM Account Data Isolation

When running as a scheduled task, all operations execute as **NT AUTHORITY\SYSTEM**:

- **SYSTEM Posh-ACME Data**: `C:\Windows\System32\config\systemprofile\AppData\Local\Posh-ACME\`
- **User Posh-ACME Data**: `C:\Users\{username}\AppData\Local\Posh-ACME\`

**Certificate data does NOT transfer between accounts.** Testing as a regular user creates certificates in a different location than scheduled task execution.

### Testing as SYSTEM

For production-accurate testing, use **PsExec** to run PowerShell as SYSTEM:

```powershell
# Download PsExec from Sysinternals
PsExec.exe -s -i powershell.exe

# Verify active Posh-ACME directory
Get-PAServer | Select-Object -ExpandProperty Folder

# Run certificate script
.\Update-Certificate.ps1 -PostScript "Set-ADFSCert.ps1" -Verbose
```

### Verbose Logging

All scripts support `-Verbose` for detailed execution logs:

```powershell
.\Update-Certificate.ps1 -PostScript "Set-ADFSCert.ps1" -Verbose
```

When running as SYSTEM (scheduled task), production logs use `Write-Verbose` to avoid cluttering event logs.

### Log Location

All orchestration and post-script logging is consolidated to the same file:

- Logs/Update-Certificate.log

This includes Register-CertificateScheduledTask.ps1, Update-Certificate.ps1, and post-scripts such as Set-CMCMGCert.ps1 and Set-NPSCert.ps1.

### Troubleshooting Common Issues

#### Scheduled Task Not Running

- Verify task exists: `Get-ScheduledTask -TaskName "Renew-Certificates-*"`
- Check task history in Task Scheduler GUI
- Ensure BitWarden credentials are accessible to SYSTEM account

#### Certificate Not Found

- Verify Posh-ACME data location: `Get-PAServer | Select-Object -ExpandProperty Folder`
- Check if running as correct user (SYSTEM vs. administrator)
- Review DNS propagation for Route53 TXT records

#### Post-Script Errors

- Ensure post-script exists in `PostScripts/` directory
- Check post-script has proper permissions
- Verify post-script parameters match expected signature

#### Secret File Lifecycle

By default, `Secret.psd1` and `BitWardenSecrets.psd1` are deleted after execution for security:

- Use `-KeepSecrets` to retain both files for debugging
- `Secret.psd1` is regenerated on each run via BitWarden CLI when BitWarden configuration is present

## Scripts Overview

| Script                                      | Purpose                                                                         | Execution Context                |
|---------------------------------------------|---------------------------------------------------------------------------------|----------------------------------|
| **Update-Certificate.ps1**                  | Main orchestration: invokes secret retrieval, runs Posh-ACME, calls post-script | Manual or Scheduled Task         |
| **Invoke-SecretFile.ps1**                   | Retrieves secrets from BitWarden and generates `Secret.psd1`                    | Called by Update-Certificate.ps1 |
| **Set-ADFSCert.ps1**                        | Post-action script: deploys certificate to AD FS                                | Called by Update-Certificate.ps1 |
| **Register-CertificateScheduledTask.ps1**   | Creates/updates Windows Scheduled Task for automation                           | Manual (one-time setup)          |

### Post-Action Scripts

Post-action scripts are located in the PostScripts/ directory and receive common runtime parameters:

- `$LatestCertThumbprint` - Certificate thumbprint for deployment
- `$UseStaging` - Flag indicating staging vs. production
- `$Verbose` - Verbose preference from Update-Certificate.ps1

Script-specific settings are loaded by each post-script from Vars.psd1 using a key that matches the script basename (without .ps1).

Example mapping:

- PostScript = Set-CMCMGCert.ps1
- Vars.psd1 key = 'Set-CMCMGCert'

**Included Post-Scripts:**

- PostScripts/Set-ADFSCert.ps1 - Deploys to Active Directory Federation Services
- PostScripts/Set-WAPCert.ps1 - Deploys to Web Application Proxy
- PostScripts/Set-CMCMGCert.ps1 - Deploys to ConfigMgr Cloud Management Gateway
- PostScripts/Set-NPSCert.ps1 - Deploys to Network Policy Server

**Create Custom Post-Scripts** in `PostScripts/` for:

- IIS certificate binding
- Exchange Server certificates
- Custom application certificate deployment

## Important Considerations

## Prerequisites

### Required Software

- **Windows Server** (tested on Server 2019+)
- **PowerShell 5.1+**
- **Posh-ACME Module** (included in repo: auto-detected from `Posh-ACME/` directory)
- **BitWarden CLI** (`bws.exe`) - [Download](https://bitwarden.com/help/secrets-manager-cli/)
- **AWS Route53** - DNS zone hosting the certificate domain(s)

### Required Permissions

- **Administrator privileges** for initial setup and scheduled task creation
- **AWS Route53** IAM credentials with permissions to modify DNS records
- **BitWarden Secrets Manager** access token

## Security Best Practices

1. **Exclude secret files from version control** (`.gitignore`)
2. **Restrict BitWarden API tokens** to minimum required permissions
3. **Use AWS IAM policies** limiting Route53 to specific hosted zones
4. **Rotate BitWarden tokens** periodically
5. **Monitor scheduled task execution** for anomalies
6. **Test in staging** before production deployments

## File Structure

```text
PSLECertManager/
├── VERSION.md                      # Project version (date-based)
├── CHANGELOG.md                    # Version history and changes
├── Update-Certificate.ps1          # Main orchestration script
├── Invoke-SecretFile.ps1           # BitWarden secret retrieval
├── Register-CertificateScheduledTask.ps1  # Scheduled task creation
├── Vars.psd1                       # Configuration (create from .example)
├── Vars.psd1.example               # Configuration template
├── BitWardenSecrets.psd1           # BitWarden config (create from .example)
├── Secret.psd1                     # Generated secrets (auto-created)
├── PROJECT_CONTEXT.md              # Detailed technical documentation
├── README.md                       # This file
├── PostScripts/                    # Post-action deployment scripts
│   ├── Set-ADFSCert.ps1           #   - ADFS certificate deployment
│   ├── Set-WAPCert.ps1            #   - WAP certificate deployment
│   ├── Set-CMCMGCert.ps1          #   - ConfigMgr CMG deployment
│   └── Set-NPSCert.ps1            #   - NPS certificate deployment
└── Posh-ACME/                      # ACME client module (local copy)
    └── */                          #   - Auto-detected version
```

## Release Management

### Versioning

This project uses **date-based versioning** in the format `YYYY.M.D` (e.g., `2026.1.20`).

### Creating a New Release

1. Update `VERSION.md` file with new date: `echo "2026.1.21" > VERSION.md`
2. Update `CHANGELOG.md` with changes following [Keep a Changelog](https://keepachangelog.com/) format
3. Commit changes: `git commit -am "Release 2026.1.21"`
4. Tag release: `git tag -a 2026.1.21 -m "Release 2026.1.21"`
5. Push with tags: `git push && git push --tags`

### Changelog Categories

- **Added**: New features
- **Changed**: Changes to existing functionality
- **Fixed**: Bug fixes
- **Security**: Security improvements

## License

This project is provided as-is for internal use by Cascade Technology Alliance.

## Support

For issues, questions, or contributions, contact the system administrator or refer to [PROJECT_CONTEXT.md](PROJECT_CONTEXT.md) for detailed technical documentation.

## Author

[Eden Nelson](https://github.com/EdenNelson) for [Cascade Technology Alliance](https://github.com/CTA-K12)
