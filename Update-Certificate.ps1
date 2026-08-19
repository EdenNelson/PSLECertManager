<#
.SYNOPSIS
    Updates SSL/TLS certificates using Posh-ACME for Let's Encrypt automation.

.DESCRIPTION
    This script automates the process of creating, renewing, and managing SSL/TLS certificates
    using the Posh-ACME module. It handles certificate lifecycle management and
    executes a post-script with the latest certificate thumbprint for deployment.

.PARAMETER PostScript
    Required. The path to a script or command to execute after obtaining or renewing a certificate.
    If not provided as a parameter, will be read from Vars.psd1.

.PARAMETER UseStaging
    Optional. Switch to use Let's Encrypt staging environment instead of production.
    Useful for testing without hitting rate limits. Staging issues a fresh certificate on every run (no renewal reuse). Can also be configured in Vars.psd1.

.PARAMETER KeepSecrets
    Optional. Switch to keep secret files after certificate creation (for debugging).
    By default, secret files are deleted for security after use.

.PARAMETER Reset
    Optional. Cleanup-only mode. Removes Posh-ACME cache folders for the current user and SYSTEM profile,
    removes certificates in LocalMachine\My matching CertFriendlyName from Vars.psd1, removes the
    project Temp directory (which may contain exported certificate artifacts), and removes the
    scheduled task for the MainDomain. No certificate issuance occurs in this mode.

.NOTES
    Author: Eden Nelson
    Created: 2025
    Version: 1.0
    Requires: Posh-ACME module

.EXAMPLE
    .\Update-Certificate.ps1 -PostScript "Set-ADFSCert.ps1"

    This example runs the script against production Let's Encrypt servers.

.EXAMPLE
    .\Update-Certificate.ps1 -UseStaging

    This example runs the script against Let's Encrypt staging servers for testing.

.EXAMPLE
    .\Update-Certificate.ps1 -Reset -Verbose

    This example resets local certificate automation state and exits.
#>
[CmdletBinding()]
param (
    [System.String]$PostScript,
    [Switch]$UseStaging,
    [Switch]$KeepSecrets,
    [Switch]$Reset
)

begin {
    $ScriptName = $MyInvocation.MyCommand.Name
    $LogDir = Join-Path -Path $PSScriptRoot -ChildPath "Logs"
    if (-not (Test-Path -Path $LogDir)) {
        New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    }
    $LogPath = Join-Path -Path $LogDir -ChildPath "Update-Certificate.log"

    # Log capacity constants
    $MAX_LOG_BYTES = 1 * 1024 * 1024          # 1MB cap per file
    $ROTATE_THRESHOLD = $MAX_LOG_BYTES - 1024  # Rotate margin to avoid exceeding
    $RETENTION_DAYS = 90                        # Purge rotated logs older than 90 days
    $MAX_ROTATION_FILES = 5                     # Max number of rotated files to keep

    function Test-LogCapacity {
        if (Test-Path -Path $LogPath) {
            $fileSize = (Get-Item -Path $LogPath).Length
            if ($fileSize -ge $ROTATE_THRESHOLD) {
                # Shift rotations descending
                for ($i = $MAX_ROTATION_FILES - 1; $i -ge 1; $i--) {
                    $current = "$LogPath.$i"
                    $next = "$LogPath.$($i + 1)"
                    if (Test-Path -Path $current) {
                        Rename-Item -Path $current -NewName (Split-Path -Path $next -Leaf) -Force
                    }
                }
                # Rename current to .1
                Rename-Item -Path $LogPath -NewName "Update-Certificate.log.1" -Force

                # Create fresh log
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                "[$timestamp] [INFO] --- Log rotated from previous file ---" | Add-Content -Path $LogPath
            }
        }

        # Purge old rotations
        $cutoffDate = (Get-Date).AddDays(-$RETENTION_DAYS)
        Get-ChildItem -Path "$LogDir/Update-Certificate.log.*" -ErrorAction SilentlyContinue |
            Where-Object -FilterScript { $_.LastWriteTime -lt $cutoffDate } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    function Write-Log {
        param (
            [Parameter(Mandatory = $true)][string]$Message,
            [Parameter()][string]$Level = "INFO"
        )
        Test-LogCapacity
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logMessage = "[$timestamp] [$Level] $Message"
        Add-Content -Path $LogPath -Value $logMessage
        if ($Level -eq "ERROR") {
            Write-Error -Message $Message
        }
        else {
            Write-Verbose -Message $Message
        }
    }

    function Initialize-Variables {
        param (
            [Parameter(Mandatory = $true)][string]$ScriptRoot
        )
        $variablesDataPath = Join-Path -Path $ScriptRoot -ChildPath "Vars.psd1"
        if (-not (Test-Path -Path $variablesDataPath)) {
            Write-Log -Message "Vars.psd1 not found at $variablesDataPath" -Level "ERROR"
            throw "Vars.psd1 is required at $variablesDataPath"
        }
        $variablesData = Import-PowerShellDataFile -Path $variablesDataPath
        $variablesData.GetEnumerator() | ForEach-Object -Process {
            Set-Variable -Name $_.Key -Value $_.Value -Scope Global
        }
        Write-Log -Message "Loaded variables: CertDomains=$CertDomains, CertFriendlyName=$CertFriendlyName"
        if (-not $PSBoundParameters.ContainsKey('PostScript') -and $variablesData.ContainsKey('PostScript')) {
            $script:PostScript = $variablesData['PostScript']
            Write-Verbose -Message "Using PostScript from Vars.psd1: $PostScript"
        }
        if (-not $PSBoundParameters.ContainsKey('UseStaging') -and $variablesData.ContainsKey('UseStaging') -and $variablesData['UseStaging']) {
            $script:UseStaging = $true
            Write-Verbose -Message "Using UseStaging from Vars.psd1: $UseStaging"
        }
        return $variablesData
    }

    function Get-CachedCredentials {
        param (
            [Parameter(Mandatory = $true)][string]$MainDomain,
            [Parameter(Mandatory = $true)][string]$ScriptRoot
        )
        Write-Log -Message "Checking for cached Posh-ACME credentials..." "INFO"
        
        # Step 1: Check for PA Account
        $paAccount = Get-PAAccount
        if (-not $paAccount) {
            Write-Log -Message "No PA Account found in Posh-ACME cache." "INFO"
            $paAccountExists = $false
        } else {
            Write-Log -Message "PA Account found: $($paAccount.Id)" "INFO"
            $paAccountExists = $true
        }
        
        # Step 2: Check for existing certificate matching MainDomain
        $existingCert = Get-PACertificate -MainDomain $MainDomain -ErrorAction SilentlyContinue
        if ($existingCert) {
            Write-Log -Message "Certificate found for $MainDomain. Status: $($existingCert.status)" "INFO"
            $certExists = $true
        } else {
            Write-Log -Message "No certificate found for $MainDomain in Posh-ACME cache" "INFO"
            $certExists = $false
        }
        
        # Step 3: Check for existing order
        $existingOrder = Get-PAOrder -List | Where-Object -FilterScript { $_.MainDomain -eq $MainDomain }
        
        # Step 4: Determine execution mode based on cache state
        $result = @{
            paAccountExists = $paAccountExists
            certExists = $certExists
            existingOrder = $existingOrder
            usesCachedCredentials = $false
            Email = $null
            R53AccessKey = $null
            R53SecretKey = $null
        }
        
        if ($paAccountExists -and $certExists -and $existingOrder) {
            # Potential RENEWAL MODE: PA Account + Certificate + Order present. An order can
            # still exist without usable cached Route53 plugin args or a contact email - e.g.
            # right after the account/cache was recreated from scratch (new API key, cleared
            # LE_PROD, etc.) - so verify the cache is actually complete before trusting it.
            # Otherwise "PASSED" is misleading and New-AcmeCertificate later fails on an empty
            # Email/R53AccessKey with a raw PowerShell parameter-binding error that is
            # non-terminating by default, silently skipping certificate issuance.
            $cachedPluginArgs = Get-PAPluginArgs -Order $existingOrder
            $cachedEmail = $paAccount.contact -join ','
            if ($cachedPluginArgs.R53AccessKey -and $cachedPluginArgs.R53SecretKey -and -not [string]::IsNullOrWhiteSpace($cachedEmail)) {
                Write-Log -Message "Cache validation PASSED: PA Account + Certificate + Order present" "INFO"
                Write-Log -Message "Using cached credentials from Posh-ACME AppData" "INFO"
                $result.usesCachedCredentials = $true
                $result.Email = $cachedEmail
                $result.R53AccessKey = $cachedPluginArgs.R53AccessKey
                $result.R53SecretKey = $cachedPluginArgs.R53SecretKey  # Already SecureString
            } else {
                Write-Log -Message "Cache validation PARTIAL: PA Account + Certificate + Order present but cached Route53 plugin args or account contact are incomplete for $MainDomain" "INFO"
                Write-Log -Message "This usually means the account or order was recently recreated (e.g. after clearing the Posh-ACME cache). Will need Route53 secrets from BitWarden." "INFO"
                $result.Email = $cachedEmail
            }
        } elseif ($paAccountExists -and -not $certExists -and $existingOrder) {
            # RECOVERY MODE: PA Account + Order present, but the local certificate file
            # (cert.cer) is missing from the Posh-ACME cache - e.g. deleted, corrupted, or
            # quarantined by AV/EDR/backup software. Get-PACertificate only ever looks for a
            # file literally named cert.cer, so it reports "no certificate" even though the
            # order's cached Route53 plugin args (pluginargs.json) are still present and valid.
            # Get-PAPluginArgs has no dependency on cert.cer, so reuse those cached credentials
            # instead of demanding fresh secrets from BitWarden.
            Write-Log -Message "Cache validation PARTIAL: PA Account + Order present but certificate file missing for $MainDomain" "INFO"
            $cachedPluginArgs = Get-PAPluginArgs -Order $existingOrder
            if ($cachedPluginArgs.R53AccessKey -and $cachedPluginArgs.R53SecretKey) {
                Write-Log -Message "Recovering using cached Route53 plugin args from existing order (no BitWarden fetch needed)" "INFO"
                $result.usesCachedCredentials = $true
                $result.Email = $paAccount.contact -join ','
                $result.R53AccessKey = $cachedPluginArgs.R53AccessKey
                $result.R53SecretKey = $cachedPluginArgs.R53SecretKey  # Already SecureString
            } else {
                Write-Log -Message "Existing order found but cached plugin args are incomplete. Will need Route53 secrets from BitWarden." "INFO"
                $result.Email = $paAccount.contact -join ','
            }
        } elseif ($paAccountExists -and -not $certExists) {
            # PARTIAL CACHE: PA Account exists but no cert and no order (new domain for existing account)
            Write-Log -Message "Cache validation PARTIAL: PA Account present but no certificate or order for $MainDomain" "INFO"
            Write-Log -Message "This is a new certificate for existing account. Will need Route53 secrets from BitWarden." "INFO"
            $result.Email = $paAccount.contact -join ','
        } else {
            # CACHE MISS: No PA Account or no cert - first run, cache cleared, or recovery
            Write-Log -Message "Cache validation FAILED: PA Account and/or Certificate missing" "INFO"
            Write-Log -Message "First run, cache reset, or recovery mode. Will need credentials from BitWarden." "INFO"
        }
        
        return $result
    }

    function Invoke-ResetState {
        param (
            [Parameter(Mandatory = $true)][string]$ScriptRoot,
            [Parameter(Mandatory = $true)][string]$CertFriendlyName,
            [Parameter(Mandatory = $true)][string]$MainDomain,
            [Parameter()][string]$ScheduledTaskPath = "\Cascade Technology Alliance"
        )

        Write-Log -Message "RESET MODE - Starting cleanup operations"

        # Remove Posh-ACME cache for current user and SYSTEM profile.
        $currentUserPoshAcmePath = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath "Posh-ACME"
        $systemProfilePoshAcmePath = Join-Path -Path $env:WINDIR -ChildPath "System32\config\systemprofile\AppData\Local\Posh-ACME"

        $cachePaths = @($currentUserPoshAcmePath, $systemProfilePoshAcmePath) | Select-Object -Unique
        foreach ($cachePath in $cachePaths) {
            if (Test-Path -Path $cachePath) {
                try {
                    Remove-Item -Path $cachePath -Recurse -Force -ErrorAction Stop
                    Write-Log -Message "Removed Posh-ACME cache path: $cachePath"
                }
                catch {
                    Write-Log -Message "Failed to remove Posh-ACME cache path '$cachePath': $_" -Level "ERROR"
                    throw
                }
            }
            else {
                Write-Log -Message "Posh-ACME cache path not found (already clean): $cachePath"
            }
        }

        # Remove matching certificates from LocalMachine\My.
        try {
            $matchingCerts = Get-ChildItem -Path Cert:\LocalMachine\My |
                Where-Object -FilterScript { $_.FriendlyName -eq $CertFriendlyName }
        }
        catch {
            Write-Log -Message "Failed to enumerate LocalMachine\\My certificates: $_" -Level "ERROR"
            throw
        }

        if ($matchingCerts -and $matchingCerts.Count -gt 0) {
            foreach ($certificate in $matchingCerts) {
                try {
                    Remove-Item -Path $certificate.PSPath -Force -ErrorAction Stop
                    Write-Log -Message "Removed certificate: Thumbprint=$($certificate.Thumbprint), FriendlyName=$($certificate.FriendlyName)"
                }
                catch {
                    Write-Log -Message "Failed to remove certificate $($certificate.Thumbprint): $_" -Level "ERROR"
                    throw
                }
            }
        }
        else {
            Write-Log -Message "No LocalMachine\\My certificates found with FriendlyName '$CertFriendlyName'"
        }

        # Remove project Temp directory that may contain exported certificate artifacts.
        $tempDirPath = Join-Path -Path $ScriptRoot -ChildPath "Temp"
        if (Test-Path -Path $tempDirPath) {
            try {
                Remove-Item -Path $tempDirPath -Recurse -Force -ErrorAction Stop
                Write-Log -Message "Removed project temp directory: $tempDirPath"
            }
            catch {
                Write-Log -Message "Failed to remove project temp directory '$tempDirPath': $_" -Level "ERROR"
                throw
            }
        }
        else {
            Write-Log -Message "Project temp directory not found (already clean): $tempDirPath"
        }

        # Remove scheduled tasks for the configured domain (primary and any post-script-suffixed variants).
        $scheduledTaskNamePrefix = "Renew-Certificates-$MainDomain"
        $scheduledTask = Get-ScheduledTask -ErrorAction SilentlyContinue |
            Where-Object -FilterScript {
                ($_.TaskPath -eq $ScheduledTaskPath -or $_.TaskPath -eq "$ScheduledTaskPath\") -and
                $_.TaskName.StartsWith($scheduledTaskNamePrefix, [System.StringComparison]::OrdinalIgnoreCase)
            }

        if ($scheduledTask) {
            foreach ($task in $scheduledTask) {
                try {
                    Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop
                    Write-Log -Message "Removed scheduled task: $($task.TaskPath)$($task.TaskName)"
                }
                catch {
                    Write-Log -Message "Failed to remove scheduled task $($task.TaskPath)$($task.TaskName): $_" -Level "ERROR"
                    throw
                }
            }
        }
        else {
            Write-Log -Message "Scheduled tasks not found (already clean): $ScheduledTaskPath\$scheduledTaskNamePrefix*"
        }

        Write-Log -Message "RESET MODE - Cleanup operations completed"
    }

    function Initialize-Secrets {
        param (
            [Parameter(Mandatory = $true)][string]$ScriptRoot,
            [Parameter()][switch]$KeepSecretsSwitch,
            [Parameter()][hashtable]$CachedCreds
        )
        
        # Check if we can use cached credentials (renewal mode)
        if ($CachedCreds.usesCachedCredentials) {
            Write-Log -Message "Using cached credentials from Posh-ACME (no BitWarden fetch needed)" "INFO"
            Set-Variable -Name "Email" -Value $CachedCreds.Email -Scope Global
            Set-Variable -Name "R53AccessKey" -Value $CachedCreds.R53AccessKey -Scope Global
            Set-Variable -Name "R53SecretKey" -Value $CachedCreds.R53SecretKey -Scope Global
            Write-Log -Message "Loaded from cache: Email present=$(![string]::IsNullOrEmpty($Email)), R53AccessKey present=$(![string]::IsNullOrEmpty($R53AccessKey)), R53SecretKey present=$($null -ne $R53SecretKey)" "INFO"
            if ([string]::IsNullOrWhiteSpace($Email) -or [string]::IsNullOrWhiteSpace($R53AccessKey) -or $null -eq $R53SecretKey) {
                Write-Log -Message "Cached credentials were incomplete (Email/R53AccessKey/R53SecretKey missing) despite cache validation reporting a hit. Aborting before New-PACertificate would fail on a missing mandatory parameter." -Level "ERROR"
                throw "Cached Posh-ACME credentials are incomplete; provide BitWardenSecrets.psd1 to recover"
            }
            return $null
        }
        
        # Need to fetch from BitWarden
        $bitWardenSecretsFile = Join-Path -Path $ScriptRoot -ChildPath "BitWardenSecrets.psd1"
        if (-not (Test-Path -Path $bitWardenSecretsFile)) {
            Write-Log -Message "BitWardenSecrets.psd1 not found and no cached credentials available." "ERROR"
            Write-Log -Message "Cannot proceed. First run or recovery requires: BitWardenSecrets.psd1 with valid BWSToken" "ERROR"
            Write-Log -Message "To recover: create or restore BitWardenSecrets.psd1 in the script root" "ERROR"
            throw "BitWardenSecrets.psd1 required but not found"
        }
        
        Write-Log -Message "BitWardenSecrets.psd1 found. Fetching credentials from BitWarden..." "INFO"
        $invokeSecretPath = Join-Path -Path $ScriptRoot -ChildPath "Invoke-SecretFile.ps1"
        Write-Log -Message "Invoking Invoke-SecretFile.ps1 to retrieve secrets..."
        & $invokeSecretPath
        $secretsDataPath = Join-Path -Path $ScriptRoot -ChildPath "Secret.psd1"
        Write-Log -Message "Secrets retrieved. Secret file path: $secretsDataPath"
        $secretsData = Import-PowerShellDataFile -Path $secretsDataPath
        $secretsData.GetEnumerator() | ForEach-Object -Process {
            Set-Variable -Name $_.Key -Value $_.Value -Scope Global
        }
        Write-Log -Message "Loaded secrets: Email present=$(![string]::IsNullOrEmpty($Email)), R53AccessKey present=$(![string]::IsNullOrEmpty($R53AccessKey)), R53SecretKey present=$(![string]::IsNullOrEmpty($R53SecretKey))"

        if ([string]::IsNullOrWhiteSpace($Email) -or [string]::IsNullOrWhiteSpace($R53AccessKey) -or [string]::IsNullOrWhiteSpace($R53SecretKey)) {
            Write-Log -Message "Required BitWarden secrets were loaded as empty values. Aborting certificate issuance." -Level "ERROR"
            throw "Required BitWarden secrets are missing or empty after retrieval"
        }
        
        # Centralized secret file cleanup for BitWarden retrieval path.
        if (-not $KeepSecretsSwitch) {
            Write-Log -Message "BitWarden retrieval complete. Cleaning secret PSD1 files."
            Remove-StaleSecretFiles -ScriptRoot $ScriptRoot -CleanupReason "post-import BitWarden cleanup"
        }
        
        return $secretsData
    }

    function Remove-StaleSecretFiles {
        param (
            [Parameter(Mandatory = $true)][string]$ScriptRoot,
            [Parameter()][string]$CleanupReason = "secret file cleanup"
        )

        $staleSecretFiles = @(
            (Join-Path -Path $ScriptRoot -ChildPath "Secret.psd1"),
            (Join-Path -Path $ScriptRoot -ChildPath "BitWardenSecrets.psd1")
        )

        foreach ($filePath in $staleSecretFiles) {
            if (Test-Path -Path $filePath) {
                try {
                    Remove-Item -Path $filePath -Force -ErrorAction Stop
                    Write-Log -Message "Removed secret file during ${CleanupReason}: $filePath"
                }
                catch {
                    Write-Log -Message "Failed to remove stale secret file '$filePath': $_" -Level "ERROR"
                    throw
                }
            }
        }
    }

    function Initialize-PoshAcmeModule {
        param (
            [Parameter(Mandatory = $true)][string]$ScriptRoot
        )
        # Dynamically detect Posh-ACME version from script root
        $poshAcmeBaseDir = Join-Path -Path $ScriptRoot -ChildPath "Posh-ACME"
        $versionDir = $null
        if (Test-Path -Path $poshAcmeBaseDir) {
            $versionDirs = Get-ChildItem -Path $poshAcmeBaseDir -Directory | Where-Object -FilterScript { $_.Name -match '^\d+\.\d+\.\d+$' }
            if ($versionDirs) {
                # Sort by version and take the latest
                $versionDir = $versionDirs | Sort-Object -Property { [version]$_.Name } -Descending | Select-Object -First 1
                Write-Log -Message "Detected Posh-ACME version: $($versionDir.Name)"
            }
        }
        if ($versionDir) {
            $poshAcmeModulePath = Join-Path -Path $versionDir.FullName -ChildPath "Posh-ACME.psm1"
            Write-Log -Message "Importing Posh-ACME from local path (signed): $poshAcmeModulePath"
            $bcPath = Join-Path -Path $versionDir.FullName -ChildPath "lib/BC.Crypto.1.8.8.2-netstandard2.0.dll"
            if (Test-Path -Path $bcPath) {
                Write-Log -Message "Loading BouncyCastle assembly from: $bcPath"
                try {
                    Add-Type -Path $bcPath -ErrorAction Stop
                    Write-Log -Message "BouncyCastle assembly loaded successfully"
                }
                catch {
                    Write-Log -Message "Warning: Could not load BouncyCastle assembly, module will attempt to load it: $_"
                }
            }
            else {
                Write-Log -Message "BouncyCastle assembly not found at $bcPath, module will attempt to load it"
            }
            Import-Module -Name $poshAcmeModulePath
        }
        else {
            Write-Log -Message "Importing Posh-ACME from system module (unsigned gallery version may fail in strict execution policy)"
            Import-Module -Name Posh-ACME
        }
    }

    function Set-AcmeServer {
        param (
            [Parameter()][switch]$UseStagingSwitch
        )
        if ($UseStagingSwitch) {
            Set-PAServer -Name LE_STAGE
            Write-Log -Message "Using Let's Encrypt STAGING environment"
            Write-Verbose -Message "Using Let's Encrypt STAGING environment"
        }
        else {
            Set-PAServer -Name LE_PROD
            Write-Log -Message "Using Let's Encrypt PRODUCTION environment"
            Write-Verbose -Message "Using Let's Encrypt PRODUCTION environment"
        }
        $serverInfo = Get-PAServer
        Write-Log -Message "Active ACME server: $($serverInfo.location)"
        Write-Log -Message "Posh-ACME data folder: $($serverInfo.Folder)"
    }

    function Get-CertificateUpdateNeeded {
        param (
            [Parameter(Mandatory = $true)][string]$MainDomain,
            [Parameter(Mandatory = $true)][string]$CertFriendlyName,
            [Parameter()][switch]$UseStagingSwitch
        )
        $needsNewCertLocal = $false
        $certificateUpdatedLocal = $false
        if ($UseStagingSwitch) {
            Write-Log -Message "Staging environment enabled: forcing new certificate"
            Write-Verbose -Message "Staging environment enabled: forcing new certificate"
            $needsNewCertLocal = $true
        }
        else {
            $existingCerts = Get-PACertificate -MainDomain $MainDomain -ErrorAction SilentlyContinue
            if ($existingCerts) {
                Write-Verbose -Message "Certificate for $MainDomain exists. Checking expiration date..."
                $storeCert = Get-ChildItem -Path Cert:\LocalMachine\My |
                    Where-Object -FilterScript { $_.FriendlyName -match $CertFriendlyName } |
                    Sort-Object -Property NotAfter -Descending |
                    Select-Object -First 1
                if (-not $storeCert -or $storeCert.NotAfter -le (Get-Date)) {
                    Write-Log -Message "No valid installed certificate found in the store for FriendlyName $CertFriendlyName; new certificate will be issued."
                    $needsNewCertLocal = $true
                }
                else {
                    Write-Verbose -Message "Installed certificate found: Thumbprint=$($storeCert.Thumbprint), NotAfter=$($storeCert.NotAfter)"
                    $expiringCerts = $existingCerts | Where-Object -FilterScript { $_.NotAfter -lt (Get-Date).AddDays(30) }
                    if ($expiringCerts) {
                        Write-Verbose -Message "Certificate for $MainDomain is expiring within 30 days. Renewing..."
                        Submit-Renewal -MainDomain $MainDomain
                        $certificateUpdatedLocal = $true
                    }
                    else {
                        Write-Verbose -Message "Certificate for $MainDomain is not expiring within 30 days. No renewal needed."
                    }
                }
            }
            else {
                Write-Verbose -Message "Certificate for $MainDomain does not exist. Creating new certificate..."
                Write-Log -Message "Certificate for $MainDomain does not exist. Creating new certificate..."
                $needsNewCertLocal = $true
            }
        }
        return @{ needsNewCert = $needsNewCertLocal; certificateUpdated = $certificateUpdatedLocal }
    }

    function New-AcmeCertificate {
        param (
            [Parameter(Mandatory = $true)][string]$CertDomains,
            [Parameter(Mandatory = $true)][string]$CertFriendlyName,
            [Parameter(Mandatory = $true)][string]$Email,
            [Parameter(Mandatory = $true)][string]$R53AccessKey,
            [Parameter(Mandatory = $true)]$R53SecretKey,  # Can be string or SecureString
            [Parameter(Mandatory = $true)][string]$MainDomain,
            [Parameter()][switch]$UseStagingSwitch
        )
        # Handle both plain text (from BitWarden) and SecureString (from Posh-ACME cache)
        if ($R53SecretKey -is [System.Security.SecureString]) {
            $R53SecretKeySecure = $R53SecretKey
        } else {
            $R53SecretKeySecure = ConvertTo-SecureString -String $R53SecretKey -AsPlainText -Force
        }
        $pArgs = @{
            R53AccessKey = $R53AccessKey
            R53SecretKey = $R53SecretKeySecure
        }
        $Contact = $Email
        Write-Verbose -Message "Creating new certificate for $MainDomain with contact $Contact"
        Write-Log -Message "Creating new certificate for domains: $CertDomains with contact configured=$(![string]::IsNullOrEmpty($Contact))"
        Write-Log -Message "Using Route53 plugin for DNS validation"
        try {
            Write-Log -Message "Calling New-PACertificate..."
            if ($UseStagingSwitch) {
                Write-Log -Message "Staging mode: creating new certificate with -Force flag"
                New-PACertificate -Domain $CertDomains -AcceptTOS -FriendlyName $CertFriendlyName -Contact $Contact -Plugin Route53 -PluginArgs $pArgs -Install -Force
            }
            else {
                New-PACertificate -Domain $CertDomains -AcceptTOS -FriendlyName $CertFriendlyName -Contact $Contact -Plugin Route53 -PluginArgs $pArgs -Install
            }
            Write-Log -Message "Certificate created successfully"
            return $true
        }
        catch {
            Write-Log -Message "Failed to create certificate for ${MainDomain}: $_" -Level "ERROR"
            Write-Error -Message "Failed to create certificate for ${MainDomain}: $_"
            throw
        }
        finally {
            Remove-Variable -Name Contact -ErrorAction SilentlyContinue
            Remove-Variable -Name R53SecretKeySecure -ErrorAction SilentlyContinue
            Remove-Variable -Name pArgs -ErrorAction SilentlyContinue
        }
    }

    function Invoke-PostScript {
        param (
            [Parameter(Mandatory = $true)][string]$CertFriendlyName,
            [Parameter(Mandatory = $true)][string]$PostScript,
            [Parameter(Mandatory = $true)][string]$ScriptRoot,
            [Parameter()][switch]$UseStagingSwitch
        )
        Write-Log -Message "Searching for certificate with FriendlyName: $CertFriendlyName"
        $availableCerts = Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object -Property FriendlyName -Match $CertFriendlyName
        Write-Log -Message "Found $($availableCerts.Count) certificate(s) matching FriendlyName"
        $latestCert = $availableCerts | Sort-Object -Property NotAfter -Descending | Select-Object -First 1
        if ($latestCert) {
            Write-Log -Message "Latest certificate: Thumbprint=$($latestCert.Thumbprint), Subject=$($latestCert.Subject), NotAfter=$($latestCert.NotAfter)"
            Write-Verbose -Message "Running post-script $PostScript with latest certificate thumbprint $($latestCert.Thumbprint)"
            
            # Resolve PostScript path - check PostScripts/ folder first, then script root
            $postScriptPath = $null
            $postScriptsFolder = Join-Path -Path $ScriptRoot -ChildPath "PostScripts"
            $postScriptInFolder = Join-Path -Path $postScriptsFolder -ChildPath $PostScript
            $postScriptInRoot = Join-Path -Path $ScriptRoot -ChildPath $PostScript
            
            if (Test-Path -Path $postScriptInFolder) {
                $postScriptPath = $postScriptInFolder
            }
            elseif (Test-Path -Path $postScriptInRoot) {
                $postScriptPath = $postScriptInRoot
            }
            else {
                Write-Log -Message "Post-script not found: $PostScript (checked PostScripts/ and script root)" -Level "ERROR"
                throw "Post-script not found: $PostScript"
            }
            
            $postArgs = @{ LatestCertThumbprint = $latestCert.Thumbprint }
            if ($UseStagingSwitch) { $postArgs['UseStaging'] = $true }
            if ($VerbosePreference -ne 'SilentlyContinue') { $postArgs['Verbose'] = $true }
            Write-Log -Message "Invoking post-script: $postScriptPath with thumbprint $($latestCert.Thumbprint)"
            & $postScriptPath @postArgs
            Write-Log -Message "Post-script execution completed"
        }
        else {
            Write-Log -Message "No certificate found with FriendlyName: $CertFriendlyName" -Level "ERROR"
        }
    }

    Write-Verbose -Message ("BEGIN: {0} starting" -f $ScriptName)
    Write-Log -Message ("========== {0} Started ==========" -f $ScriptName)
    Write-Log -Message ("Running as user: {0}" -f $env:USERNAME)
    Write-Log -Message ("Script root: {0}" -f $PSScriptRoot)
    }

    process {
        Write-Verbose -Message "PROCESS: No pipeline input to process."
    }

    end {
        $variablesData = Initialize-Variables -ScriptRoot $PSScriptRoot

        $MainDomain = $CertDomains -split ',' | Select-Object -First 1
        Write-Log -Message ("MainDomain: {0}" -f $MainDomain)

        if ($Reset) {
            Write-Log -Message "Reset mode requested"
            Invoke-ResetState -ScriptRoot $PSScriptRoot -CertFriendlyName $CertFriendlyName -MainDomain $MainDomain
            Write-Log -Message "Reset mode complete. Exiting without certificate issuance."
            Write-Log -Message ("========== {0} Completed (Reset) ==========" -f $ScriptName)
            return
        }

        Initialize-PoshAcmeModule -ScriptRoot $PSScriptRoot

        if (-not $PostScript) {
            Write-Log -Message "PostScript is required but not provided" -Level "ERROR"
            throw "PostScript is required. Provide it via -PostScript parameter or configure it in Vars.psd1"
        }

        Set-AcmeServer -UseStagingSwitch:$UseStaging

        # Check for cached credentials BEFORE determining if we need a certificate
        Write-Log -Message "Execution context: $(if ($env:USERNAME -eq 'SYSTEM') { 'SYSTEM (scheduled task)' } else { 'User: ' + $env:USERNAME })" "INFO"
        $serverInfo = Get-PAServer
        Write-Log -Message "Posh-ACME AppData folder: $($serverInfo.Folder)" "INFO"
        
        $cachedCreds = Get-CachedCredentials -MainDomain $MainDomain -ScriptRoot $PSScriptRoot

        # Explicit override: a present BitWardenSecrets.psd1 means an operator deliberately
        # dropped it in (e.g. after rotating the Route53 API key) or a prior run failed before
        # cleanup. Either way, cache validation can only check that credentials are PRESENT,
        # not that they are still VALID against AWS - a rotated key still looks like a
        # complete cache hit. Treat the file's presence as intent to bypass the cache and pull
        # the current secret from BitWarden instead, and do this before the stale-file cleanup
        # below so it doesn't delete the very file we're about to use.
        $bitWardenSecretsPath = Join-Path -Path $PSScriptRoot -ChildPath "BitWardenSecrets.psd1"
        if ($cachedCreds.usesCachedCredentials -and (Test-Path -Path $bitWardenSecretsPath)) {
            Write-Log -Message "BitWardenSecrets.psd1 found despite a valid-looking Posh-ACME cache. Treating this as an explicit override to use current BitWarden credentials instead of the (possibly stale) cache." "INFO"
            $cachedCreds.usesCachedCredentials = $false
        }

        if ($cachedCreds.usesCachedCredentials -and -not $KeepSecrets) {
            Write-Log -Message "Cached credentials detected. Cleaning any leftover secret PSD1 files."
            Remove-StaleSecretFiles -ScriptRoot $PSScriptRoot -CleanupReason "cached-credential stale file cleanup"
        }

        $updateStatus = Get-CertificateUpdateNeeded -MainDomain $MainDomain -CertFriendlyName $CertFriendlyName -UseStagingSwitch:$UseStaging
        $needsNewCert = $updateStatus.needsNewCert
        $certificateUpdated = $updateStatus.certificateUpdated

        if ($needsNewCert) {
            # Initialize secrets (will use cache if available, BitWarden if not)
            Initialize-Secrets -ScriptRoot $PSScriptRoot -KeepSecretsSwitch:$KeepSecrets -CachedCreds $cachedCreds
            
            # Convert R53SecretKey to SecureString if it came from BitWarden (plain text)
            # If from cache, it's already SecureString
            if (-not $cachedCreds.usesCachedCredentials) {
                $R53SecretKeySecure = ConvertTo-SecureString -String $R53SecretKey -AsPlainText -Force
                Set-Variable -Name "R53SecretKey" -Value $R53SecretKeySecure -Scope Global
            }
            
            if (New-AcmeCertificate -CertDomains $CertDomains -CertFriendlyName $CertFriendlyName -Email $Email -R53AccessKey $R53AccessKey -R53SecretKey $R53SecretKey -MainDomain $MainDomain -UseStagingSwitch:$UseStaging) {
                $certificateUpdated = $true
            }
        }

        if ($certificateUpdated) {
            Invoke-PostScript -CertFriendlyName $CertFriendlyName -PostScript $PostScript -ScriptRoot $PSScriptRoot -UseStagingSwitch:$UseStaging
        }
        elseif ($needsNewCert) {
            # Hard invariant: if we determined a certificate was needed, we must end this run
            # with either a certificate or a thrown/logged error - never a quiet no-op. Every
            # known path to this point (Initialize-Secrets, New-AcmeCertificate) already throws
            # on failure, but this is a deliberate backstop against a future change silently
            # reintroducing a no-op path here (see the 2026-08-19 incident: an incomplete cache
            # hit let the script report "no update needed" after silently failing to issue).
            Write-Log -Message "Certificate issuance was needed for $MainDomain but the run completed without one being installed. Treat cached and/or BitWarden credentials as suspect." -Level "ERROR"
            throw "Certificate update was required for $MainDomain but did not complete"
        }
        else {
            Write-Log -Message "No certificate update needed. Skipping post-script execution."
                Write-Log -Message ("Credentials source: {0}" -f $(if ($cachedCreds.usesCachedCredentials) { 'Posh-ACME Cache (renewal)' } else { 'BitWarden (first run or new cert)' })) "INFO"
        }

        Write-Log -Message ("========== {0} Completed ==========" -f $ScriptName)
    }


#endregion Certificate
# SIG # Begin signature block
# MIIgGwYJKoZIhvcNAQcCoIIgDDCCIAgCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUmoBs9BhMxQpkg8r7Yip09xAV
# qHygghpMMIIGMTCCBRmgAwIBAgITXQAAAkSPdub9u4IuqwADAAACRDANBgkqhkiG
# 9w0BAQsFADBaMRMwEQYKCZImiZPyLGQBGRYDb3JnMRswGQYKCZImiZPyLGQBGRYL
# Y2FzY2FkZXRlY2gxFTATBgoJkiaJk/IsZAEZFgVpbnRyYTEPMA0GA1UEAxMGQ1RB
# LUNBMB4XDTE3MDMyNzE4NDEwMFoXDTI3MDMyNTE4NDEwMFowbjETMBEGCgmSJomT
# 8ixkARkWA29yZzEbMBkGCgmSJomT8ixkARkWC2Nhc2NhZGV0ZWNoMRUwEwYKCZIm
# iZPyLGQBGRYFaW50cmExDTALBgNVBAsTBE1FU0QxFDASBgNVBAMTC0VkZW4gTmVs
# c29uMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA6t55EHD8rTEtKnmr
# foxUKjVUM9Eu6/4lcnLFJFaXAAGFp6HKkZoQFNgVvd4pfMYXvYV1mq/Z1PxYeACm
# jOjVxLwtUCx3N2GX439aFtvxRX+Kc1SJ223NfPPq86dgzVupascWtmFB6srs79if
# LXH6yqEYPiQlnfXDf2Bkomx0HcPLcqKpplsRToyLWOCGDkvovii2E+cGlaSPHE6R
# ekyz7NioJHeqw/n7DgFxR+zHK0ekIr5It9WST6vo1eOvVSIxEA4IsVFt0KNuMt4Q
# hwvP0msZevIklGx9AE8Ptomk9EfPUtGH0C23BuGzN5XsqaJoLclNjle4MXlMrrkZ
# MCvkPwIDAQABo4IC2jCCAtYwPAYJKwYBBAGCNxUHBC8wLQYlKwYBBAGCNxUIgdub
# PYHF4BGB8Y8AhveZM9LraYEKuqx8h6nAfQIBZAIBAjATBgNVHSUEDDAKBggrBgEF
# BQcDAzAOBgNVHQ8BAf8EBAMCB4AwGwYJKwYBBAGCNxUKBA4wDDAKBggrBgEFBQcD
# AzAdBgNVHQ4EFgQU1/EpGs3xdVYJkUujLTWDc1kWxcYwHwYDVR0jBBgwFoAURbUV
# cNI0zRtVrM0lx4fqlrvCJZ8wggERBgNVHR8EggEIMIIBBDCCAQCggf2ggfqGgb9s
# ZGFwOi8vL0NOPUNUQS1DQSgyKSxDTj1DVEEtREMtMDEsQ049Q0RQLENOPVB1Ymxp
# YyUyMEtleSUyMFNlcnZpY2VzLENOPVNlcnZpY2VzLENOPUNvbmZpZ3VyYXRpb24s
# REM9aW50cmEsREM9Y2FzY2FkZXRlY2gsREM9b3JnP2NlcnRpZmljYXRlUmV2b2Nh
# dGlvbkxpc3Q/YmFzZT9vYmplY3RDbGFzcz1jUkxEaXN0cmlidXRpb25Qb2ludIY2
# aHR0cDovL2N0YWNybC5jYXNjYWRldGVjaC5vcmcvQ2VydEVucm9sbC9DVEEtQ0Eo
# MikuY3JsMIHFBggrBgEFBQcBAQSBuDCBtTCBsgYIKwYBBQUHMAKGgaVsZGFwOi8v
# L0NOPUNUQS1DQSxDTj1BSUEsQ049UHVibGljJTIwS2V5JTIwU2VydmljZXMsQ049
# U2VydmljZXMsQ049Q29uZmlndXJhdGlvbixEQz1pbnRyYSxEQz1jYXNjYWRldGVj
# aCxEQz1vcmc/Y0FDZXJ0aWZpY2F0ZT9iYXNlP29iamVjdENsYXNzPWNlcnRpZmlj
# YXRpb25BdXRob3JpdHkwNwYDVR0RBDAwLqAsBgorBgEEAYI3FAIDoB4MHG5lbHNv
# bkBpbnRyYS5jYXNjYWRldGVjaC5vcmcwDQYJKoZIhvcNAQELBQADggEBADqKPu55
# +4xpvtgMmdeU1pdFYz83yntNhvlf2ikI+ASsqvoVi1XDXeKcZak6lxdO7NTZ1R7I
# KMyQWsM3/JUGTCpgaeSJwTfa7C/uDCvLXKLvsbURoQWG2bPMzno30Oy4yUKASg6Y
# 46ibMgsIrQHnNjMhphF0gIhjKqI+XS44avQjH+78SAoI+ET0JB2qdojlg76VUpfB
# rfhcuSVzRuRFUFwX8taI2bHRTAa6XXsFXTJsHua5gvmtF9zSvr5A+h+JJmWXNhpg
# 579bpytyrIztoDJ2JzhkrhJl0QPZ7klj2yRcSFLGc59qfhX1kDYM8/cJxRaXRyBB
# yr5Gl7Zg87N3+uQwggaCMIIEaqADAgECAhA2wrC9fBs656Oz3TbLyXVoMA0GCSqG
# SIb3DQEBDAUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKTmV3IEplcnNleTEU
# MBIGA1UEBxMLSmVyc2V5IENpdHkxHjAcBgNVBAoTFVRoZSBVU0VSVFJVU1QgTmV0
# d29yazEuMCwGA1UEAxMlVVNFUlRydXN0IFJTQSBDZXJ0aWZpY2F0aW9uIEF1dGhv
# cml0eTAeFw0yMTAzMjIwMDAwMDBaFw0zODAxMTgyMzU5NTlaMFcxCzAJBgNVBAYT
# AkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28g
# UHVibGljIFRpbWUgU3RhbXBpbmcgUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCIndi5RWedHd3ouSaBmlRUwHxJBZvMWhUP2ZQQRLRBQIF3
# FJmp1OR2LMgIU14g0JIlL6VXWKmdbmKGRDILRxEtZdQnOh2qmcxGzjqemIk8et8s
# E6J+N+Gl1cnZocew8eCAawKLu4TRrCoqCAT8uRjDeypoGJrruH/drCio28aqIVEn
# 45NZiZQI7YYBex48eL78lQ0BrHeSmqy1uXe9xN04aG0pKG9ki+PC6VEfzutu6Q3I
# cZZfm00r9YAEp/4aeiLhyaKxLuhKKaAdQjRaf/h6U13jQEV1JnUTCm511n5avv4N
# +jSVwd+Wb8UMOs4netapq5Q/yGyiQOgjsP/JRUj0MAT9YrcmXcLgsrAimfWY3MzK
# m1HCxcquinTqbs1Q0d2VMMQyi9cAgMYC9jKc+3mW62/yVl4jnDcw6ULJsBkOkrcP
# LUwqj7poS0T2+2JMzPP+jZ1h90/QpZnBkhdtixMiWDVgh60KmLmzXiqJc6lGwqoU
# qpq/1HVHm+Pc2B6+wCy/GwCcjw5rmzajLbmqGygEgaj/OLoanEWP6Y52Hflef3XL
# vYnhEY4kSirMQhtberRvaI+5YsD3XVxHGBjlIli5u+NrLedIxsE88WzKXqZjj9Zi
# 5ybJL2WjeXuOTbswB7XjkZbErg7ebeAQUQiS/uRGZ58NHs57ZPUfECcgJC+v2wID
# AQABo4IBFjCCARIwHwYDVR0jBBgwFoAUU3m/WqorSs9UgOHYm8Cd8rIDZsswHQYD
# VR0OBBYEFPZ3at0//QET/xahbIICL9AKPRQlMA4GA1UdDwEB/wQEAwIBhjAPBgNV
# HRMBAf8EBTADAQH/MBMGA1UdJQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYE
# VR0gADBQBgNVHR8ESTBHMEWgQ6BBhj9odHRwOi8vY3JsLnVzZXJ0cnVzdC5jb20v
# VVNFUlRydXN0UlNBQ2VydGlmaWNhdGlvbkF1dGhvcml0eS5jcmwwNQYIKwYBBQUH
# AQEEKTAnMCUGCCsGAQUFBzABhhlodHRwOi8vb2NzcC51c2VydHJ1c3QuY29tMA0G
# CSqGSIb3DQEBDAUAA4ICAQAOvmVB7WhEuOWhxdQRh+S3OyWM637ayBeR7djxQ8Si
# hTnLf2sABFoB0DFR6JfWS0snf6WDG2gtCGflwVvcYXZJJlFfym1Doi+4PfDP8s0c
# qlDmdfyGOwMtGGzJ4iImyaz3IBae91g50QyrVbrUoT0mUGQHbRcF57olpfHhQESt
# z5i6hJvVLFV/ueQ21SM99zG4W2tB1ExGL98idX8ChsTwbD/zIExAopoe3l6JrzJt
# Pxj8V9rocAnLP2C8Q5wXVVZcbw4x4ztXLsGzqZIiRh5i111TW7HV1AtsQa6vXy63
# 3vCAbAOIaKcLAo/IU7sClyZUk62XD0VUnHD+YvVNvIGezjM6CRpcWed/ODiptK+e
# vDKPU2K6synimYBaNH49v9Ih24+eYXNtI38byt5kIvh+8aW88WThRpv8lUJKaPn3
# 7+YHYafob9Rg7LyTrSYpyZoBmwRWSE4W6iPjB7wJjJpH29308ZkpKKdpkiS9WNsf
# /eeUtvRrtIEiSJHN899L1P4l6zKVsdrUu1FX1T/ubSrsxrYJD+3f3aKg6yxdbugo
# t06YwGXXiy5UUGZvOu3lXlxA+fC13dQ5OlL2gIb5lmF6Ii8+CQOYDwXM+yd9dbmo
# cQsHjcRPsccUd5E9FiswEqORvz8g3s+jR3SFCgXhN4wz7NgAnOgpCdUo4uDyllU9
# PzCCBqcwggSPoAMCAQICEQCQrAhyIP3Fp8RrXMcN9z0GMA0GCSqGSIb3DQEBDAUA
# MFcxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNV
# BAMTJVNlY3RpZ28gUHVibGljIFRpbWUgU3RhbXBpbmcgUm9vdCBSNDYwHhcNMjYw
# MzI1MDAwMDAwWhcNNDEwMzI0MjM1OTU5WjBVMQswCQYDVQQGEwJHQjEYMBYGA1UE
# ChMPU2VjdGlnbyBMaW1pdGVkMSwwKgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1l
# IFN0YW1waW5nIENBIFI0MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIB
# AK7kSqIBrYIcYvlmLVuaA8zw1RfBhkn4G1CoemzjcYtML6yNUvKmwGH7y6/5MuSC
# 1UYP/+9KYDSqvMQt/1hEKHYxMAD9oZpBkoaDQFEKbOJHelsKe+BaO0ZcENTKfePc
# raVkA7wrGAW2XHA5gQCQv4IKori/3PNOXxnDMOk8yIMgVrlMeTxqfWJ4XkjT1xc2
# s9DD7URHWWJOFobTPoWs6mrDFlaY9FlAHDYTfbzvxQHVsvRmn3W+5ZmCwyk02I8K
# gGPT/UX4sTz41GiR+ppwUjQXa1+2tEHZbsdAKUtH3OPEVtZvlt7atx4h83IdRR8o
# Yi8wjY3OjFKXFecWpQbzzsPxbUKPwMWiTrzwkrFa8dH/1pDKRJt371W62PfqKPay
# Cr/XbnBOlRn8CALSmHnRtGzuAWtTJpcT3BKw6oy8IIL6wSbu938F6ZIbRNIc1dKb
# IJtr4ULN6R5ZfTdNEhwXctqp3RHDbg4fuOl6LjNoaFwjud92EEDhzxFJzE1jqN4c
# sceZIwxOT1aqfsfh0uFQE/lgTBuBs3i6/WL2W1OceWLy3XEdXRK1f0EWCuea6dNf
# X2RRdjUfk5EltFnJkN2+bWhnK14OPRKcyjOv5hKZ0iV4NRNd1+hjtva1rPyzb5Bs
# 7EvFxqEQhgZbOq7qH3nm0rBwA0dxniBOYCFPdu246JCxAgMBAAGjggFuMIIBajAf
# BgNVHSMEGDAWgBT2d2rdP/0BE/8WoWyCAi/QCj0UJTAdBgNVHQ4EFgQUOnSlDGfG
# QlDC/bX8x7spNIL0erkwDgYDVR0PAQH/BAQDAgGGMBIGA1UdEwEB/wQIMAYBAf8C
# AQAwEwYDVR0lBAwwCgYIKwYBBQUHAwgwIwYDVR0gBBwwGjAIBgZngQwBBAIwDgYM
# KwYBBAGyMQECAQMIMEwGA1UdHwRFMEMwQaA/oD2GO2h0dHA6Ly9jcmwuc2VjdGln
# by5jb20vU2VjdGlnb1B1YmxpY1RpbWVTdGFtcGluZ1Jvb3RSNDYuY3JsMHwGCCsG
# AQUFBwEBBHAwbjBHBggrBgEFBQcwAoY7aHR0cDovL2NydC5zZWN0aWdvLmNvbS9T
# ZWN0aWdvUHVibGljVGltZVN0YW1waW5nUm9vdFI0Ni5wN2MwIwYIKwYBBQUHMAGG
# F2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3DQEBDAUAA4ICAQAy3lJH
# ZvGeA2b43yhzoarvobHVzbfl+RfuPDwej0wCQkYAN6scTt2GwFe22qbOCv/tllqF
# lLKQZE+E9jVyuPTbyQHwrM7R0oLapAEDC1+CowsqSRf/ptira5Pfd4PoHICnb9co
# PQtyZmHSQp5y9IGvqWf1qNfq7V2fHZ8DvEQrLUzeoGF9BJRYu2OzacW3QQtUum3N
# OVf0gPRwv6I4991uhncJ6VP4lcpUpHZKB7R3hiIUC09mR9KjzPVnXHvL9n2bAwiU
# ECfK5Zezhiw27F2tgi39DETfU8M4n0N6xLgFzsf05M5GURX8C9+IX9V6kpmmKtrU
# zMti4LD66gtmf+mSm934K81NL6YQeMEk1rpYrWPypcW76Mir6wb1AgseLIHqn/Gk
# euQm7zOTDf3f5WoX14qVNjZWNHF3JxkutV6ZnhinfCLfdv5bnwKWUfceqOajCVnt
# I6uCbHxjBg6SCsexc5AfIGno7gVFvwifT4XONPsSUaJ71XsJ+EvciVUVnjOO4qxm
# 0fWJTd8a7jP8mc4ZPqwJvQFtOp7+6G+kUJAF0fnE8YgD8uttBReNTa1YmAeFMiqc
# 38e8fI4eLm0zjM/eeGCHasnoqqrbGwcF41iz9HXzFDwN4iD5z3QShp6HRiU3UpTw
# DJiiXcr0z6pjl7PyzJ3/tmWtGehV7CAfc/WlyzCCBuIwggTKoAMCAQICEQDnTvJV
# sFBP+tum3/f8i6MVMA0GCSqGSIb3DQEBDAUAMFUxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxLDAqBgNVBAMTI1NlY3RpZ28gUHVibGljIFRp
# bWUgU3RhbXBpbmcgQ0EgUjQxMB4XDTI2MDMyNTAwMDAwMFoXDTM3MDYyNDIzNTk1
# OVowcjELMAkGA1UEBhMCR0IxFzAVBgNVBAgTDkdyZWF0ZXIgTG9uZG9uMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxMDAuBgNVBAMTJ1NlY3RpZ28gUHVibGljIFRp
# bWUgU3RhbXBpbmcgU2lnbmVyIFIzNzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBALL/w21L3FDZRS0FEXfZuPtUrefibnRSqOT/NNyJLOJhXjQfUspqHT+g
# SSVgbjYThUI/cO+wFQHoOakKQNnSMKdkE8gR69ofXlkk5DAVY/ZlevliOUmlvrw2
# Vuz4SU28rHfb/Vgd17eqpRIvJuO6XE8vPpPzn4c4iorszUF6nwuynKEQ/+rqfDmQ
# bFNKsa+5+Z4f4kXwKdUFxUwUDjQWUhiHRwMlUWGF9N91aAvL+9a4sxCgqR/ez8W8
# HJ/XqvSu1vIeb+J6bDFKKgkv3PJkMMpQ0BsdeXR2FejZXFRXY1w9dZe6gqyMv7px
# +TpWbYMefECUV0WxoEMgXUk6RKcLo94uUHOdmfZu4Xe8ghglyro3/N4VEKTj8dcP
# PvOBGxFEx1QH6uHKTkWhloGPDScurcZnd8KUtTHl6zmlQDHM04MwGfsmQViKnYEA
# YE8RHl5XRE6GTq0ZMb59SIyJX6+CODVic/kW+dhbIS1Z5AP8HaGne/PRG+12QzSn
# eKDJp3Ot+k4GrmmlWT9iy6FNCQ/32K+d4cAZ+Ll7uWbEn6Z6gE+tEu7MyZvzWvPN
# sRKMkcyyflFW1zpRyzutwypALXc9Qg7sFsYERNXa58KZXqU9Onc/tck6+adQJFM9
# tW8xOnE//P5I4eDj84IGGKqzgUD37ihC+WST3DfY0YBKWL0ZaubnAgMBAAGjggGO
# MIIBijAfBgNVHSMEGDAWgBQ6dKUMZ8ZCUML9tfzHuyk0gvR6uTAdBgNVHQ4EFgQU
# YRDpehKvUcSF1PLPpHQPUM0gr/gwDgYDVR0PAQH/BAQDAgbAMAwGA1UdEwEB/wQC
# MAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwSgYDVR0gBEMwQTAIBgZngQwBBAIw
# NQYMKwYBBAGyMQECAQMIMCUwIwYIKwYBBQUHAgEWF2h0dHBzOi8vc2VjdGlnby5j
# b20vQ1BTMEoGA1UdHwRDMEEwP6A9oDuGOWh0dHA6Ly9jcmwuc2VjdGlnby5jb20v
# U2VjdGlnb1B1YmxpY1RpbWVTdGFtcGluZ0NBUjQxLmNybDB6BggrBgEFBQcBAQRu
# MGwwRQYIKwYBBQUHMAKGOWh0dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1
# YmxpY1RpbWVTdGFtcGluZ0NBUjQxLmNydDAjBggrBgEFBQcwAYYXaHR0cDovL29j
# c3Auc2VjdGlnby5jb20wDQYJKoZIhvcNAQEMBQADggIBAAPqPY3RrM36GXqTpsoH
# n9TpW5I6z3dkFvc9zPL1W0Egq7j3jtnkbAvRoWeAjGX4ZK4sWsmA+u4EJG8okQmy
# buS/4tDUI5UIQb21n4hG2vihxShrneWB0VoQ2VLQ3jCCRmRtAQ+/7H7WVKNiH5Pg
# l4v2ZTOdPsStzpKnl1YuRrmww/+bcZmLqgk909ywIpZqAfubYfbEMYjIckLk90f2
# mG+L8qaGSS2JJVM02pV5XltZ1fbOFETpRN/PQhwygIv33qUUjJ1fE4ITgw0McMzR
# qziWdOJP8ocxxw7qXxz1OdRWCalyL1qvUgAFnZTVdSRiMYZKf0wLcQcM/1Xf1W4F
# W9nff8ERX8RZJGt/TtPuMWmUpf6BCv9Q6o8YyUTtknvZRpSQ0nLttWXdtwsrN2mM
# gfMuR//gxVrVXvDzCoK/lbiA6dEZOW53lQwBFtEzwE/FH8JdhegyYg4PymZOTZrG
# BEvgsbxe25yEhJ0IdGa1pwCYsarldJhJVMdNcAOU7jyIMqHcczav3wtIXp/SwbXZ
# 3xX0mfsLfANSJ47G4qPgx1atb6GIlTaQXzu/p4fTQeAIUVzZXT4K984IyfuO7NLj
# WMtog1wGUpZD98pv+4Mt9Y5bvfPUjaUVjtePy1DVdi0rl5ESNYi0zyOmXVxtA5zz
# xu1H7RdLZOZugT/XjX69rY9bMYIFOTCCBTUCAQEwcTBaMRMwEQYKCZImiZPyLGQB
# GRYDb3JnMRswGQYKCZImiZPyLGQBGRYLY2FzY2FkZXRlY2gxFTATBgoJkiaJk/Is
# ZAEZFgVpbnRyYTEPMA0GA1UEAxMGQ1RBLUNBAhNdAAACRI925v27gi6rAAMAAAJE
# MAkGBSsOAwIaBQCgeDAYBgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3
# DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEV
# MCMGCSqGSIb3DQEJBDEWBBRj13yjSFgz2aOlb/BrbaqHON591TANBgkqhkiG9w0B
# AQEFAASCAQC/1S47Muamr6EAQyBSm0kJiP1brBuhx5aOOHfNjqX+C7TPpprsZl5K
# WX0gSQBh7zUkIT4p7iucKA5t6FWSXVThQAZMXJjswJA9wF96ea5tANl9AGfeTfrk
# jxW5jEEgwwOo127TL3OJacTZHCLJzyMpopKfNDhS2ASWi0srjpatHZb7JhOO5fgc
# nnwB0P5hq2WCisMeJioFWc6mZWHsgBxRxrT1zul6RsoTsvJF1ushlxFuRAMcM6Ax
# /0kNQ4j8T6JtQ8s/wPMXtGClJ+TGpEVjHsXWT013eV4O4AyHX9r/D46P4UvJb+Nc
# tqYrUwMaOwYs5o8Wr7MRXGIva735/Yd2oYIDIzCCAx8GCSqGSIb3DQEJBjGCAxAw
# ggMMAgEBMGowVTELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3RpZ28gTGltaXRl
# ZDEsMCoGA1UEAxMjU2VjdGlnbyBQdWJsaWMgVGltZSBTdGFtcGluZyBDQSBSNDEC
# EQDnTvJVsFBP+tum3/f8i6MVMA0GCWCGSAFlAwQCAgUAoHkwGAYJKoZIhvcNAQkD
# MQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYwODE5MjEyNTAzWjA/Bgkq
# hkiG9w0BCQQxMgQwPapx5Dinr7TEOx0MaGVxTvS6Htgc22hMPUH9LeEG3k/43zTh
# IffKPB8Mb4OO0Wl9MA0GCSqGSIb3DQEBAQUABIICAHAhbPb3crh9HMpZ2BcsXekq
# 3eHg1Ua80W4yyfcHAJCwxad3dZ5peuyvSykuKufw3ggLwlS8oyhuYGDqkV6URezJ
# O+OVHLslhgA4skiYDHIh3YsRMTwq5IQCQtdAjrZM+uE6n8XdkMj9X6bgPjfkUJub
# V7u60sEp5DxWwnQw9xRZDdaggrKQMwaT7pnvIEdmSe/kTSdcjpLCNAoNdn1TQ04w
# xPFkBU8Klg3b8SR3ClS9ofPQvOsub/QPzu2x4d24a8I6wTSQJgqo+fFUfROmNxDF
# d9KUksn1Frf+FMAjuDPd1QVlavVDZz1rMbouK8yRqiOFwCR6KjMwyQz+mEBG1QA0
# rLYkh2HQhfZXF6qGiJA3GY9c6wXCW+RWLfjzKV7j4xjPP2uD6g8Q5v0Lw7EA5hKw
# rQ4Hqk0pKrfkr8SoyDB/03vNMLz6IWiE6HnLNVmB8VTwKg7qqiEsogaM6+eJBarT
# Xi+hbKErcLGvN99iguw4sMhCL6OlIicjdn8LGgdphf2zbNyQhnSnR4x83opDkMIi
# 6X5A1vhiXQxxzhcdtCamocsCOyEbibjR7UXiuc+9ahGdgkaXvJXKmLmDECj4AsDs
# zyHZCnSidzpMrpuY6WypO/hJ7Pnvpkp2sRrXU5GGuMlgbZ5tbzLdVs3E7hL+ycDU
# qvcDdj1yndG44ecAfMcj
# SIG # End signature block
