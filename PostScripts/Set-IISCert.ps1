<#
.SYNOPSIS
    Deploys a Let's Encrypt certificate to IIS HTTPS bindings.

.DESCRIPTION
    This script is a post-action script invoked after successful certificate creation or renewal by Update-Certificate.ps1.
    It handles both staging and production certificate deployments to Internet Information Services (IIS):

    - STAGING mode: Validates that the certificate was created and exists in the certificate store.
      No changes are made to IIS bindings (staging certificates are untrusted by browsers).

    - PRODUCTION mode: Deploys the certificate to IIS by:
      1. Validating the certificate exists in LocalMachine\My
      2. Rebinding matching IIS HTTPS bindings to the new certificate thumbprint (via http.sys)
      3. (Optional) Creating an HTTPS binding on a site if one does not already exist

    IIS binding changes take effect immediately through http.sys; no IIS/service restart is required.

    Configuration is self-discovered from Vars.psd1 under the 'Set-IISCert' subobject. ALL keys are optional:
      - Sites                  : Array of site names to target (e.g. @('Default Web Site')). Omit/empty = ALL sites that
                                 have HTTPS bindings.
      - Port                   : HTTPS port to target/create (default: 443).
      - StoreName              : Certificate store the binding should reference (default: 'My').
      - CreateBindingIfMissing : $true to create an HTTPS binding on a targeted site that has none (default: $false).
                                 Only honored when 'Sites' is explicitly listed (so we never invent bindings server-wide).
      - HostHeader             : Host header to use when creating a binding (default: '' = all unassigned / no SNI).
      - IPAddress              : IP address to use when creating a binding (default: '*').
      - RequireSNI             : $true to set the SNI flag (SslFlags=1) on a binding that is being created (default: $false).

    If the 'Set-IISCert' subobject is absent from Vars.psd1, the script defaults to rebinding EVERY existing
    HTTPS binding on the server to the new certificate. This is the common "replace the old SAN/wildcard cert
    everywhere" behavior.

.PARAMETER LatestCertThumbprint
    Required. The thumbprint of the certificate to deploy. This is provided by Update-Certificate.ps1 after certificate creation.

.PARAMETER UseStaging
    Optional. Flag indicating whether the certificate came from Let's Encrypt staging environment.
    When present, the script validates the certificate without making any IIS changes.

.NOTES
    Author: Cascade Technology Alliance (IIS post-script; follows the Set-NPSCert.ps1 / Set-WAPCert.ps1 pattern)
    Created: 2026
    Project Version: See VERSION and CHANGELOG.md in project root

    Called By: Update-Certificate.ps1 as a post-action script

    Execution Context: NT AUTHORITY\SYSTEM (when run from scheduled task)

    Requirements:
    - IIS (Web-Server role) installed; WebAdministration module available
    - Administrator/SYSTEM privileges
    - Certificate must be in LocalMachine\My certificate store (Posh-ACME -Install places it there)
    - Windows Server 2016 or later

.EXAMPLE
    .\Set-IISCert.ps1 -LatestCertThumbprint "ABC123DEF456" -Verbose

    Deploys the certificate with thumbprint ABC123DEF456 to IIS in production mode.

.EXAMPLE
    .\Set-IISCert.ps1 -LatestCertThumbprint "ABC123DEF456" -UseStaging -Verbose

    Validates the staging certificate with thumbprint ABC123DEF456 without deploying to IIS.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$LatestCertThumbprint,

    [Parameter(Mandatory = $false)]
    [switch]$UseStaging
)

#region Main Script
begin {
    #region Logging Setup
    $script:ScriptName = $MyInvocation.MyCommand.Name
    $script:LogDir = Join-Path -Path $PSScriptRoot -ChildPath "..\Logs"
    if (-not (Test-Path -Path $script:LogDir)) {
        New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null
    }
    $script:LogPath = Join-Path -Path $script:LogDir -ChildPath "Update-Certificate.log"
    function script:Write-Log {
        param(
            [Parameter(Mandatory = $true)][string]$Message,
            [Parameter()][string]$Level = "INFO"
        )
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logMessage = "[$timestamp] [$Level] [$script:ScriptName] $Message"
        Add-Content -Path $script:LogPath -Value $logMessage
        if ($Level -eq "ERROR") {
            Write-Error -Message $Message
        }
        else {
            Write-Verbose -Message $Message
        }
    }
    #endregion Logging Setup

    #region Self-Discover Config from Vars.psd1
    # Config is OPTIONAL for IIS. Absence of the 'Set-IISCert' subobject means "rebind all existing HTTPS bindings".
    $script:IisSites = @()
    $script:IisPort = 443
    $script:IisStoreName = 'My'
    $script:IisCreateIfMissing = $false
    $script:IisHostHeader = ''
    $script:IisIPAddress = '*'
    $script:IisRequireSNI = $false

    $varsPath = Join-Path -Path $PSScriptRoot -ChildPath "..\Vars.psd1"
    if (Test-Path -Path $varsPath) {
        $scriptKey = $script:ScriptName.Replace('.ps1', '')
        $config = (Import-PowerShellDataFile -Path $varsPath)[$scriptKey]
        if ($config) {
            if ($config.ContainsKey('Sites') -and $config.Sites) { $script:IisSites = @($config.Sites) }
            if ($config.ContainsKey('Port') -and $config.Port) { $script:IisPort = [int]$config.Port }
            if ($config.ContainsKey('StoreName') -and $config.StoreName) { $script:IisStoreName = [string]$config.StoreName }
            if ($config.ContainsKey('CreateBindingIfMissing')) { $script:IisCreateIfMissing = [bool]$config.CreateBindingIfMissing }
            if ($config.ContainsKey('HostHeader')) { $script:IisHostHeader = [string]$config.HostHeader }
            if ($config.ContainsKey('IPAddress') -and $config.IPAddress) { $script:IisIPAddress = [string]$config.IPAddress }
            if ($config.ContainsKey('RequireSNI')) { $script:IisRequireSNI = [bool]$config.RequireSNI }
        }
    }
    #endregion Self-Discover Config from Vars.psd1

    Write-Log "BEGIN: $script:ScriptName starting"
    Write-Log "Running as user: $env:USERNAME"
    Write-Log "Certificate thumbprint: $LatestCertThumbprint"
    Write-Log "UseStaging: $UseStaging"
    Write-Log ("Target sites: {0}" -f $(if ($script:IisSites.Count -gt 0) { $script:IisSites -join ', ' } else { 'ALL sites with HTTPS bindings' }))
    Write-Log "Target HTTPS port: $script:IisPort"
    Write-Log "Certificate store for binding: $script:IisStoreName"
    Write-Log "Create binding if missing: $script:IisCreateIfMissing"
    Write-Verbose -Message "BEGIN block completed"
}

end {
    Write-Log "========== $script:ScriptName Started =========="

    # In staging, just verify the cert was issued and skip deployment
    if ($UseStaging) {
        Write-Log "STAGING MODE - Certificate validation only"
        Write-Verbose -Message "===== STAGING MODE - Certificate validation only ====="

        $cert = Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object -FilterScript { $_.Thumbprint -eq $LatestCertThumbprint }
        if ($cert) {
            Write-Log "Certificate found in LocalMachine\My store: Subject=$($cert.Subject), NotAfter=$($cert.NotAfter)"
            Write-Verbose -Message "  Subject: $($cert.Subject)"
            Write-Verbose -Message "  Issuer: $($cert.Issuer)"
            Write-Verbose -Message "  NotBefore: $($cert.NotBefore)"
            Write-Verbose -Message "  NotAfter: $($cert.NotAfter)"
            Write-Verbose -Message "  DNS Names: $($cert.DnsNameList.Unicode -join ', ')"
            Write-Verbose -Message "Staging certificate NOT deployed to IIS (staging certificates are not trusted)."
            Write-Verbose -Message "To deploy to production, run without -UseStaging parameter."
            Write-Log "Staging validation completed successfully"
        }
        else {
            Write-Log "Certificate with thumbprint $LatestCertThumbprint not found in certificate store" "ERROR"
            exit 1
        }

        Write-Log "========== $script:ScriptName Completed (Staging) =========="
        return
    }

    Write-Log "PRODUCTION MODE - Deploying certificate to IIS"
    Write-Verbose -Message "===== PRODUCTION MODE - Deploying certificate to IIS ====="

    # Validate the certificate is present in the store the bindings will reference.
    $storePath = "Cert:\LocalMachine\$script:IisStoreName"
    $cert = Get-ChildItem -Path $storePath -ErrorAction SilentlyContinue | Where-Object -FilterScript { $_.Thumbprint -eq $LatestCertThumbprint }
    if (-not $cert) {
        Write-Log "Certificate with thumbprint $LatestCertThumbprint not found in $storePath. Cannot bind to IIS." "ERROR"
        exit 1
    }
    Write-Log "Certificate validated in ${storePath}: Subject=$($cert.Subject), NotAfter=$($cert.NotAfter)"

    # Load the IIS management module.
    try {
        Import-Module WebAdministration -ErrorAction Stop
        Write-Log "WebAdministration module imported"
    }
    catch {
        Write-Log "Failed to import WebAdministration module. Is the IIS Web-Server role installed? $_" "ERROR"
        exit 1
    }

    # Determine which sites to target.
    if ($script:IisSites.Count -gt 0) {
        $targetSites = @()
        foreach ($siteName in $script:IisSites) {
            $site = Get-Website -Name $siteName -ErrorAction SilentlyContinue
            if ($site) {
                $targetSites += $site
            }
            else {
                Write-Log "Configured site '$siteName' does not exist on this server; skipping." "WARN"
            }
        }
    }
    else {
        $targetSites = Get-Website
    }

    if (-not $targetSites -or $targetSites.Count -eq 0) {
        Write-Log "No IIS sites available to update." "ERROR"
        exit 1
    }

    $bindingsUpdated = 0
    $bindingsCreated = 0

    foreach ($site in $targetSites) {
        $siteName = $site.Name
        $httpsBindings = @(Get-WebBinding -Name $siteName -Protocol https -ErrorAction SilentlyContinue |
                Where-Object -FilterScript { ($_.bindingInformation -split ':')[1] -eq "$script:IisPort" })

        if ($httpsBindings.Count -eq 0) {
            Write-Log "Site '$siteName' has no HTTPS binding on port $script:IisPort."

            # Only create bindings when the site was explicitly targeted and creation is enabled.
            $siteWasExplicit = ($script:IisSites -contains $siteName)
            if ($script:IisCreateIfMissing -and $siteWasExplicit) {
                try {
                    $newBindingParams = @{
                        Name       = $siteName
                        Protocol   = 'https'
                        Port       = $script:IisPort
                        IPAddress  = $script:IisIPAddress
                        HostHeader = $script:IisHostHeader
                    }
                    if ($script:IisRequireSNI) { $newBindingParams['SslFlags'] = 1 }
                    New-WebBinding @newBindingParams -ErrorAction Stop
                    Write-Log "Created HTTPS binding on '$siteName' (IP=$script:IisIPAddress, Port=$script:IisPort, Host='$script:IisHostHeader', SNI=$script:IisRequireSNI)"
                    $bindingsCreated++
                    $httpsBindings = @(Get-WebBinding -Name $siteName -Protocol https -ErrorAction SilentlyContinue |
                            Where-Object -FilterScript { ($_.bindingInformation -split ':')[1] -eq "$script:IisPort" })
                }
                catch {
                    Write-Log "Failed to create HTTPS binding on '$siteName': $_" "ERROR"
                    continue
                }
            }
            else {
                continue
            }
        }

        foreach ($binding in $httpsBindings) {
            try {
                # AddSslCertificate registers the cert in http.sys for this binding's IP:port(:hostheader),
                # honoring the binding's existing SNI flag. It also replaces any previously bound certificate.
                $binding.AddSslCertificate($LatestCertThumbprint, $script:IisStoreName)
                Write-Log "Bound cert $LatestCertThumbprint to '$siteName' binding [$($binding.bindingInformation)] (store: $script:IisStoreName)"
                $bindingsUpdated++
            }
            catch {
                Write-Log "Failed to bind cert to '$siteName' binding [$($binding.bindingInformation)]: $_" "ERROR"
            }
        }
    }

    Write-Log "IIS deployment summary: $bindingsUpdated binding(s) bound, $bindingsCreated binding(s) created."

    if ($bindingsUpdated -eq 0 -and $bindingsCreated -eq 0) {
        Write-Log "No HTTPS bindings were updated. Verify site names, HTTPS port, and that HTTPS bindings exist." "ERROR"
        exit 1
    }

    Write-Log "========== $script:ScriptName Completed Successfully =========="
    Write-Verbose -Message "IIS certificate deployment completed successfully. Thumbprint: $LatestCertThumbprint"
}
#endregion Main Script
