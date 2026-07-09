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
            # RENEWAL MODE: Full cache hit - all cached credentials available
            Write-Log -Message "Cache validation PASSED: PA Account + Certificate + Order present" "INFO"
            Write-Log -Message "Using cached credentials from Posh-ACME AppData" "INFO"
            $cachedPluginArgs = Get-PAPluginArgs -Order $existingOrder
            $result.usesCachedCredentials = $true
            $result.Email = $paAccount.contact -join ','
            $result.R53AccessKey = $cachedPluginArgs.R53AccessKey
            $result.R53SecretKey = $cachedPluginArgs.R53SecretKey  # Already SecureString
        } elseif ($paAccountExists -and -not $certExists) {
            # PARTIAL CACHE: PA Account exists but no cert (new domain for existing account)
            Write-Log -Message "Cache validation PARTIAL: PA Account present but no certificate for $MainDomain" "INFO"
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
                    Write-Log -Message "Removed secret file during $CleanupReason: $filePath"
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
        else {
            Write-Log -Message "No certificate update needed. Skipping post-script execution."
                Write-Log -Message ("Credentials source: {0}" -f $(if ($cachedCreds.usesCachedCredentials) { 'Posh-ACME Cache (renewal)' } else { 'BitWarden (first run or new cert)' })) "INFO"
        }

        Write-Log -Message ("========== {0} Completed ==========" -f $ScriptName)
    }
#endregion Certificate Re
# SIG # Begin signature block
# MIIfCAYJKoZIhvcNAQcCoIIe+TCCHvUCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUURTiI73LnVCya9mpwGpN4nTX
# 0Sugghk5MIIGFDCCA/ygAwIBAgIQeiOu2lNplg+RyD5c9MfjPzANBgkqhkiG9w0B
# AQwFADBXMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMS4w
# LAYDVQQDEyVTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIFJvb3QgUjQ2MB4X
# DTIxMDMyMjAwMDAwMFoXDTM2MDMyMTIzNTk1OVowVTELMAkGA1UEBhMCR0IxGDAW
# BgNVBAoTD1NlY3RpZ28gTGltaXRlZDEsMCoGA1UEAxMjU2VjdGlnbyBQdWJsaWMg
# VGltZSBTdGFtcGluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGK
# AoIBgQDNmNhDQatugivs9jN+JjTkiYzT7yISgFQ+7yavjA6Bg+OiIjPm/N/t3nC7
# wYUrUlY3mFyI32t2o6Ft3EtxJXCc5MmZQZ8AxCbh5c6WzeJDB9qkQVa46xiYEpc8
# 1KnBkAWgsaXnLURoYZzksHIzzCNxtIXnb9njZholGw9djnjkTdAA83abEOHQ4ujO
# GIaBhPXG2NdV8TNgFWZ9BojlAvflxNMCOwkCnzlH4oCw5+4v1nssWeN1y4+RlaOy
# wwRMUi54fr2vFsU5QPrgb6tSjvEUh1EC4M29YGy/SIYM8ZpHadmVjbi3Pl8hJiTW
# w9jiCKv31pcAaeijS9fc6R7DgyyLIGflmdQMwrNRxCulVq8ZpysiSYNi79tw5RHW
# ZUEhnRfs/hsp/fwkXsynu1jcsUX+HuG8FLa2BNheUPtOcgw+vHJcJ8HnJCrcUWhd
# Fczf8O+pDiyGhVYX+bDDP3GhGS7TmKmGnbZ9N+MpEhWmbiAVPbgkqykSkzyYVr15
# OApZYK8CAwEAAaOCAVwwggFYMB8GA1UdIwQYMBaAFPZ3at0//QET/xahbIICL9AK
# PRQlMB0GA1UdDgQWBBRfWO1MMXqiYUKNUoC6s2GXGaIymzAOBgNVHQ8BAf8EBAMC
# AYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDCDARBgNV
# HSAECjAIMAYGBFUdIAAwTAYDVR0fBEUwQzBBoD+gPYY7aHR0cDovL2NybC5zZWN0
# aWdvLmNvbS9TZWN0aWdvUHVibGljVGltZVN0YW1waW5nUm9vdFI0Ni5jcmwwfAYI
# KwYBBQUHAQEEcDBuMEcGCCsGAQUFBzAChjtodHRwOi8vY3J0LnNlY3RpZ28uY29t
# L1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBpbmdSb290UjQ2LnA3YzAjBggrBgEFBQcw
# AYYXaHR0cDovL29jc3Auc2VjdGlnby5jb20wDQYJKoZIhvcNAQEMBQADggIBABLX
# eyCtDjVYDJ6BHSVY/UwtZ3Svx2ImIfZVVGnGoUaGdltoX4hDskBMZx5NY5L6SCcw
# DMZhHOmbyMhyOVJDwm1yrKYqGDHWzpwVkFJ+996jKKAXyIIaUf5JVKjccev3w16m
# NIUlNTkpJEor7edVJZiRJVCAmWAaHcw9zP0hY3gj+fWp8MbOocI9Zn78xvm9XKGB
# p6rEs9sEiq/pwzvg2/KjXE2yWUQIkms6+yslCRqNXPjEnBnxuUB1fm6bPAV+Tsr/
# Qrd+mOCJemo06ldon4pJFbQd0TQVIMLv5koklInHvyaf6vATJP4DfPtKzSBPkKlO
# tyaFTAjD2Nu+di5hErEVVaMqSVbfPzd6kNXOhYm23EWm6N2s2ZHCHVhlUgHaC4AC
# MRCgXjYfQEDtYEK54dUwPJXV7icz0rgCzs9VI29DwsjVZFpO4ZIVR33LwXyPDbYF
# kLqYmgHjR3tKVkhh9qKV2WCmBuC27pIOx6TYvyqiYbntinmpOqh/QPAnhDgexKG9
# GX/n1PggkGi9HCapZp8fRwg8RftwS21Ln61euBG0yONM6noD2XQPrFwpm3GcuqJM
# f0o8LLrFkSLRQNwxPDDkWXhW+gZswbaiie5fd/W2ygcto78XCSPfFWveUOSZ5SqK
# 95tBO8aTHmEa4lpJVD7HrTEn9jb1EGvxOb1cnn0CMIIGMTCCBRmgAwIBAgITXQAA
# AkSPdub9u4IuqwADAAACRDANBgkqhkiG9w0BAQsFADBaMRMwEQYKCZImiZPyLGQB
# GRYDb3JnMRswGQYKCZImiZPyLGQBGRYLY2FzY2FkZXRlY2gxFTATBgoJkiaJk/Is
# ZAEZFgVpbnRyYTEPMA0GA1UEAxMGQ1RBLUNBMB4XDTE3MDMyNzE4NDEwMFoXDTI3
# MDMyNTE4NDEwMFowbjETMBEGCgmSJomT8ixkARkWA29yZzEbMBkGCgmSJomT8ixk
# ARkWC2Nhc2NhZGV0ZWNoMRUwEwYKCZImiZPyLGQBGRYFaW50cmExDTALBgNVBAsT
# BE1FU0QxFDASBgNVBAMTC0VkZW4gTmVsc29uMIIBIjANBgkqhkiG9w0BAQEFAAOC
# AQ8AMIIBCgKCAQEA6t55EHD8rTEtKnmrfoxUKjVUM9Eu6/4lcnLFJFaXAAGFp6HK
# kZoQFNgVvd4pfMYXvYV1mq/Z1PxYeACmjOjVxLwtUCx3N2GX439aFtvxRX+Kc1SJ
# 223NfPPq86dgzVupascWtmFB6srs79ifLXH6yqEYPiQlnfXDf2Bkomx0HcPLcqKp
# plsRToyLWOCGDkvovii2E+cGlaSPHE6Rekyz7NioJHeqw/n7DgFxR+zHK0ekIr5I
# t9WST6vo1eOvVSIxEA4IsVFt0KNuMt4QhwvP0msZevIklGx9AE8Ptomk9EfPUtGH
# 0C23BuGzN5XsqaJoLclNjle4MXlMrrkZMCvkPwIDAQABo4IC2jCCAtYwPAYJKwYB
# BAGCNxUHBC8wLQYlKwYBBAGCNxUIgdubPYHF4BGB8Y8AhveZM9LraYEKuqx8h6nA
# fQIBZAIBAjATBgNVHSUEDDAKBggrBgEFBQcDAzAOBgNVHQ8BAf8EBAMCB4AwGwYJ
# KwYBBAGCNxUKBA4wDDAKBggrBgEFBQcDAzAdBgNVHQ4EFgQU1/EpGs3xdVYJkUuj
# LTWDc1kWxcYwHwYDVR0jBBgwFoAURbUVcNI0zRtVrM0lx4fqlrvCJZ8wggERBgNV
# HR8EggEIMIIBBDCCAQCggf2ggfqGgb9sZGFwOi8vL0NOPUNUQS1DQSgyKSxDTj1D
# VEEtREMtMDEsQ049Q0RQLENOPVB1YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNl
# cnZpY2VzLENOPUNvbmZpZ3VyYXRpb24sREM9aW50cmEsREM9Y2FzY2FkZXRlY2gs
# REM9b3JnP2NlcnRpZmljYXRlUmV2b2NhdGlvbkxpc3Q/YmFzZT9vYmplY3RDbGFz
# cz1jUkxEaXN0cmlidXRpb25Qb2ludIY2aHR0cDovL2N0YWNybC5jYXNjYWRldGVj
# aC5vcmcvQ2VydEVucm9sbC9DVEEtQ0EoMikuY3JsMIHFBggrBgEFBQcBAQSBuDCB
# tTCBsgYIKwYBBQUHMAKGgaVsZGFwOi8vL0NOPUNUQS1DQSxDTj1BSUEsQ049UHVi
# bGljJTIwS2V5JTIwU2VydmljZXMsQ049U2VydmljZXMsQ049Q29uZmlndXJhdGlv
# bixEQz1pbnRyYSxEQz1jYXNjYWRldGVjaCxEQz1vcmc/Y0FDZXJ0aWZpY2F0ZT9i
# YXNlP29iamVjdENsYXNzPWNlcnRpZmljYXRpb25BdXRob3JpdHkwNwYDVR0RBDAw
# LqAsBgorBgEEAYI3FAIDoB4MHG5lbHNvbkBpbnRyYS5jYXNjYWRldGVjaC5vcmcw
# DQYJKoZIhvcNAQELBQADggEBADqKPu55+4xpvtgMmdeU1pdFYz83yntNhvlf2ikI
# +ASsqvoVi1XDXeKcZak6lxdO7NTZ1R7IKMyQWsM3/JUGTCpgaeSJwTfa7C/uDCvL
# XKLvsbURoQWG2bPMzno30Oy4yUKASg6Y46ibMgsIrQHnNjMhphF0gIhjKqI+XS44
# avQjH+78SAoI+ET0JB2qdojlg76VUpfBrfhcuSVzRuRFUFwX8taI2bHRTAa6XXsF
# XTJsHua5gvmtF9zSvr5A+h+JJmWXNhpg579bpytyrIztoDJ2JzhkrhJl0QPZ7klj
# 2yRcSFLGc59qfhX1kDYM8/cJxRaXRyBByr5Gl7Zg87N3+uQwggZiMIIEyqADAgEC
# AhEApCk7bh7d16c0CIetek63JDANBgkqhkiG9w0BAQwFADBVMQswCQYDVQQGEwJH
# QjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSwwKgYDVQQDEyNTZWN0aWdvIFB1
# YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNjAeFw0yNTAzMjcwMDAwMDBaFw0zNjAz
# MjEyMzU5NTlaMHIxCzAJBgNVBAYTAkdCMRcwFQYDVQQIEw5XZXN0IFlvcmtzaGly
# ZTEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTAwLgYDVQQDEydTZWN0aWdvIFB1
# YmxpYyBUaW1lIFN0YW1waW5nIFNpZ25lciBSMzYwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQDThJX0bqRTePI9EEt4Egc83JSBU2dhrJ+wY7JgReuff5KQ
# NhMuzVytzD+iXazATVPMHZpH/kkiMo1/vlAGFrYN2P7g0Q8oPEcR3h0SftFNYxxM
# h+bj3ZNbbYjwt8f4DsSHPT+xp9zoFuw0HOMdO3sWeA1+F8mhg6uS6BJpPwXQjNSH
# pVTCgd1gOmKWf12HSfSbnjl3kDm0kP3aIUAhsodBYZsJA1imWqkAVqwcGfvs6pbf
# s/0GE4BJ2aOnciKNiIV1wDRZAh7rS/O+uTQcb6JVzBVmPP63k5xcZNzGo4DOTV+s
# M1nVrDycWEYS8bSS0lCSeclkTcPjQah9Xs7xbOBoCdmahSfg8Km8ffq8PhdoAXYK
# OI+wlaJj+PbEuwm6rHcm24jhqQfQyYbOUFTKWFe901VdyMC4gRwRAq04FH2VTjBd
# CkhKts5Py7H73obMGrxN1uGgVyZho4FkqXA8/uk6nkzPH9QyHIED3c9CGIJ098hU
# 4Ig2xRjhTbengoncXUeo/cfpKXDeUcAKcuKUYRNdGDlf8WnwbyqUblj4zj1kQZSn
# Zud5EtmjIdPLKce8UhKl5+EEJXQp1Fkc9y5Ivk4AZacGMCVG0e+wwGsjcAADRO7W
# ga89r/jJ56IDK773LdIsL3yANVvJKdeeS6OOEiH6hpq2yT+jJ/lHa9zEdqFqMwID
# AQABo4IBjjCCAYowHwYDVR0jBBgwFoAUX1jtTDF6omFCjVKAurNhlxmiMpswHQYD
# VR0OBBYEFIhhjKEqN2SBKGChmzHQjP0sAs5PMA4GA1UdDwEB/wQEAwIGwDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMEoGA1UdIARDMEEwNQYM
# KwYBBAGyMQECAQMIMCUwIwYIKwYBBQUHAgEWF2h0dHBzOi8vc2VjdGlnby5jb20v
# Q1BTMAgGBmeBDAEEAjBKBgNVHR8EQzBBMD+gPaA7hjlodHRwOi8vY3JsLnNlY3Rp
# Z28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBpbmdDQVIzNi5jcmwwegYIKwYB
# BQUHAQEEbjBsMEUGCCsGAQUFBzAChjlodHRwOi8vY3J0LnNlY3RpZ28uY29tL1Nl
# Y3RpZ29QdWJsaWNUaW1lU3RhbXBpbmdDQVIzNi5jcnQwIwYIKwYBBQUHMAGGF2h0
# dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3DQEBDAUAA4IBgQACgT6khnJR
# IfllqS49Uorh5ZvMSxNEk4SNsi7qvu+bNdcuknHgXIaZyqcVmhrV3PHcmtQKt0bl
# v/8t8DE4bL0+H0m2tgKElpUeu6wOH02BjCIYM6HLInbNHLf6R2qHC1SUsJ02MWNq
# RNIT6GQL0Xm3LW7E6hDZmR8jlYzhZcDdkdw0cHhXjbOLsmTeS0SeRJ1WJXEzqt25
# dbSOaaK7vVmkEVkOHsp16ez49Bc+Ayq/Oh2BAkSTFog43ldEKgHEDBbCIyba2E8O
# 5lPNan+BQXOLuLMKYS3ikTcp/Qw63dxyDCfgqXYUhxBpXnmeSO/WA4NwdwP35lWN
# hmjIpNVZvhWoxDL+PxDdpph3+M5DroWGTc1ZuDa1iXmOFAK4iwTnlWDg3QNRsRa9
# cnG3FBBpVHnHOEQj4GMkrOHdNDTbonEeGvZ+4nSZXrwCW4Wv2qyGDBLlKk3kUW1p
# IScDCpm/chL6aUbnSsrtbepdtbCLiGanKVR/KC1gsR0tC6Q0RfWOI4owggaCMIIE
# aqADAgECAhA2wrC9fBs656Oz3TbLyXVoMA0GCSqGSIb3DQEBDAUAMIGIMQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKTmV3IEplcnNleTEUMBIGA1UEBxMLSmVyc2V5IENp
# dHkxHjAcBgNVBAoTFVRoZSBVU0VSVFJVU1QgTmV0d29yazEuMCwGA1UEAxMlVVNF
# UlRydXN0IFJTQSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTAeFw0yMTAzMjIwMDAw
# MDBaFw0zODAxMTgyMzU5NTlaMFcxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0
# aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28gUHVibGljIFRpbWUgU3RhbXBp
# bmcgUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCIndi5
# RWedHd3ouSaBmlRUwHxJBZvMWhUP2ZQQRLRBQIF3FJmp1OR2LMgIU14g0JIlL6VX
# WKmdbmKGRDILRxEtZdQnOh2qmcxGzjqemIk8et8sE6J+N+Gl1cnZocew8eCAawKL
# u4TRrCoqCAT8uRjDeypoGJrruH/drCio28aqIVEn45NZiZQI7YYBex48eL78lQ0B
# rHeSmqy1uXe9xN04aG0pKG9ki+PC6VEfzutu6Q3IcZZfm00r9YAEp/4aeiLhyaKx
# LuhKKaAdQjRaf/h6U13jQEV1JnUTCm511n5avv4N+jSVwd+Wb8UMOs4netapq5Q/
# yGyiQOgjsP/JRUj0MAT9YrcmXcLgsrAimfWY3MzKm1HCxcquinTqbs1Q0d2VMMQy
# i9cAgMYC9jKc+3mW62/yVl4jnDcw6ULJsBkOkrcPLUwqj7poS0T2+2JMzPP+jZ1h
# 90/QpZnBkhdtixMiWDVgh60KmLmzXiqJc6lGwqoUqpq/1HVHm+Pc2B6+wCy/GwCc
# jw5rmzajLbmqGygEgaj/OLoanEWP6Y52Hflef3XLvYnhEY4kSirMQhtberRvaI+5
# YsD3XVxHGBjlIli5u+NrLedIxsE88WzKXqZjj9Zi5ybJL2WjeXuOTbswB7XjkZbE
# rg7ebeAQUQiS/uRGZ58NHs57ZPUfECcgJC+v2wIDAQABo4IBFjCCARIwHwYDVR0j
# BBgwFoAUU3m/WqorSs9UgOHYm8Cd8rIDZsswHQYDVR0OBBYEFPZ3at0//QET/xah
# bIICL9AKPRQlMA4GA1UdDwEB/wQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MBMGA1Ud
# JQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYEVR0gADBQBgNVHR8ESTBHMEWg
# Q6BBhj9odHRwOi8vY3JsLnVzZXJ0cnVzdC5jb20vVVNFUlRydXN0UlNBQ2VydGlm
# aWNhdGlvbkF1dGhvcml0eS5jcmwwNQYIKwYBBQUHAQEEKTAnMCUGCCsGAQUFBzAB
# hhlodHRwOi8vb2NzcC51c2VydHJ1c3QuY29tMA0GCSqGSIb3DQEBDAUAA4ICAQAO
# vmVB7WhEuOWhxdQRh+S3OyWM637ayBeR7djxQ8SihTnLf2sABFoB0DFR6JfWS0sn
# f6WDG2gtCGflwVvcYXZJJlFfym1Doi+4PfDP8s0cqlDmdfyGOwMtGGzJ4iImyaz3
# IBae91g50QyrVbrUoT0mUGQHbRcF57olpfHhQEStz5i6hJvVLFV/ueQ21SM99zG4
# W2tB1ExGL98idX8ChsTwbD/zIExAopoe3l6JrzJtPxj8V9rocAnLP2C8Q5wXVVZc
# bw4x4ztXLsGzqZIiRh5i111TW7HV1AtsQa6vXy633vCAbAOIaKcLAo/IU7sClyZU
# k62XD0VUnHD+YvVNvIGezjM6CRpcWed/ODiptK+evDKPU2K6synimYBaNH49v9Ih
# 24+eYXNtI38byt5kIvh+8aW88WThRpv8lUJKaPn37+YHYafob9Rg7LyTrSYpyZoB
# mwRWSE4W6iPjB7wJjJpH29308ZkpKKdpkiS9WNsf/eeUtvRrtIEiSJHN899L1P4l
# 6zKVsdrUu1FX1T/ubSrsxrYJD+3f3aKg6yxdbugot06YwGXXiy5UUGZvOu3lXlxA
# +fC13dQ5OlL2gIb5lmF6Ii8+CQOYDwXM+yd9dbmocQsHjcRPsccUd5E9FiswEqOR
# vz8g3s+jR3SFCgXhN4wz7NgAnOgpCdUo4uDyllU9PzGCBTkwggU1AgEBMHEwWjET
# MBEGCgmSJomT8ixkARkWA29yZzEbMBkGCgmSJomT8ixkARkWC2Nhc2NhZGV0ZWNo
# MRUwEwYKCZImiZPyLGQBGRYFaW50cmExDzANBgNVBAMTBkNUQS1DQQITXQAAAkSP
# dub9u4IuqwADAAACRDAJBgUrDgMCGgUAoHgwGAYKKwYBBAGCNwIBDDEKMAigAoAA
# oQKAADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4w
# DAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQUyKsY2cZSht5DcKgCTbPJ4sl+
# 778wDQYJKoZIhvcNAQEBBQAEggEA4+NKXaWHCQ4f7zoQB1z6KLiT5pAzSvWdVZge
# XNeY/QfQ7DJZrKgfYEe6SoczJd9dBUI40Qr5Bb40Z9KNO3TdD2RwdpAsxFYjZRUL
# l+cs/J5xpuSbFlyjI3A1ANKoSsxcBxcHjRluWxNEM02eTFOuEY1jGkA2blAfXnuo
# QhTbm+q+eTf8PJyZRBR5BoVp7aMW6XKr+TQEoISA0gnkZvTCg0+dKWOaU9xwbD3i
# 0jutfSOxuLqI4bryzOsWh2PdS6X7P3ZEYJ1bBdIOGudnpT5QeowS37g/uMkhedal
# qCf/m5WYvCJA463WtKmIWT9fw1N0I3HmmMNaQmt1eLInytvvRKGCAyMwggMfBgkq
# hkiG9w0BCQYxggMQMIIDDAIBATBqMFUxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9T
# ZWN0aWdvIExpbWl0ZWQxLDAqBgNVBAMTI1NlY3RpZ28gUHVibGljIFRpbWUgU3Rh
# bXBpbmcgQ0EgUjM2AhEApCk7bh7d16c0CIetek63JDANBglghkgBZQMEAgIFAKB5
# MBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDQy
# NDE3NDYzMlowPwYJKoZIhvcNAQkEMTIEMNrBjZHpXue8NJ2+ZZajTEtCPqVoyE7h
# cDqpoJvabVH/++i8LZ9h8iYBAnDmp9AVLjANBgkqhkiG9w0BAQEFAASCAgBzgDnv
# Uw4tXDThYVG+on7kvYEvolJZJC4nmi9UrUiJiHFSN+OoSayzaoMLeZxpbh2PKE32
# QiP/wQyd3yeISf5pFOQUHjOuEYo99l95uPUDZaVUwzMJ2p04JGjlHVFkQ72YKmLc
# Ac0fdZdrfy8mp0WNWpfPuibLbZMPFkO/O4cUHRIFvmg4NqnB1RfiEP5kNjh+Qy/4
# Wy/cLliaorFlQl/PGIPPB7agxWHfVRYDLJQ8viPY6UbzEVKR1WwX24xyQgB2C315
# XWBPubs/tPEDf5N3hMbco121LZTqYCJ/uB1E+JGs9UwyVA1xN1nX1/0aB/Wl88Je
# /OfBl8Reea8gfNGp/52577Ejb5GDsSlSklqCz8YdpcQpC4HC4noLwd9abV+dS7Gh
# LopaDEjI31jtMMGddv9g7NEvW9ejcR0lIhoD9Y9p4m8yrBrjWR0rwhq2OYh1UdHP
# IwenDTauyly+4xg4wyB7JpQt/p71A2cZL/HB2KWERiP9GEQc7uTvgARC1oLJyAls
# GI9n5e+tZIRsEsIDuuHm7WyuYTrCv8BmwOpGJBXuDRpOo7N62VemXQEAFTjBJaie
# gt3c93pNLlEegiucIiJ9p5ejeSbNuDWoVkLkiEkWb5NkwHasipuV97Q61KI1EqLs
# GCdFg7XU9d5z8qT6L3+V3Je+quY2UscdGbtdHA==
# SIG # End signature block
