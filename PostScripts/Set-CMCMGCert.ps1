<#
.SYNOPSIS
    Deploys a Let's Encrypt certificate to Microsoft Configuration Manager Cloud Management Gateway (CMG).

.DESCRIPTION
    Post-action script invoked by Update-Certificate.ps1. Validates the issued certificate and, in
    production mode, exports it to a temporary PFX and updates the CMG service certificate via
    Set-CMCloudManagementGateway. Configuration is self-discovered from Vars.psd1 under the
    'Set-CMCMGCert' subobject (Name, SiteCode). An ephemeral PFX password is generated per run
    and never persisted.

.PARAMETER LatestCertThumbprint
    Thumbprint of the certificate to deploy. Provided by Update-Certificate.ps1.

.PARAMETER UseStaging
    When present, performs validation only and does not modify CMG configuration.

.NOTES
    Author: Eden Nelson
    Created: 2025
    Project Version: See VERSION and CHANGELOG.md in project root
    Called By: Update-Certificate.ps1 as a post-action script
    Config Source: Vars.psd1 → 'Set-CMCMGCert' subobject (Name, SiteCode)
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$LatestCertThumbprint,

    [Parameter()]
    [switch]$UseStaging
)

begin {
    #region Logging Setup
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
        $logMessage = "[$timestamp] [$Level] [Set-CMCMGCert] $Message"
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
    $varsPath = Join-Path -Path $PSScriptRoot -ChildPath "..\Vars.psd1"
    if (-not (Test-Path -Path $varsPath)) {
        throw "Vars.psd1 not found at $varsPath"
    }
    $scriptKey = $MyInvocation.MyCommand.Name.Replace('.ps1', '')
    $config = (Import-PowerShellDataFile -Path $varsPath)[$scriptKey]
    if (-not $config) {
        throw "No configuration subobject '$scriptKey' found in Vars.psd1"
    }
    if (-not $config.Name) {
        throw "'$scriptKey.Name' (CMG service instance name) is required in Vars.psd1"
    }
    if (-not $config.SiteCode) {
        throw "'$scriptKey.SiteCode' (Configuration Manager site code) is required in Vars.psd1"
    }
    #endregion Self-Discover Config from Vars.psd1

    Write-Log -Message "BEGIN: Set-CMCMGCert.ps1 starting"
    Write-Log -Message "Running as user: $env:USERNAME"
    Write-Log -Message "Certificate thumbprint: $LatestCertThumbprint"
    Write-Log -Message "CMG Name: $($config.Name)"
    Write-Log -Message "SiteCode: $($config.SiteCode)"
    Write-Log -Message "UseStaging: $UseStaging"
}

end {
    $ErrorActionPreference = 'Stop'

    Write-Log -Message "========== Set-CMCMGCert.ps1 Started =========="

    #region Validate Certificate
    $cert = Get-ChildItem -Path Cert:\LocalMachine\My |
        Where-Object -FilterScript { $_.Thumbprint -eq $LatestCertThumbprint }
    if (-not $cert) {
        Write-Log -Message "Certificate with thumbprint $LatestCertThumbprint not found in LocalMachine\My" -Level "ERROR"
        throw "Certificate with thumbprint $LatestCertThumbprint not found in LocalMachine\\My"
    }
    Write-Log -Message "Certificate found: Subject=$($cert.Subject); NotAfter=$($cert.NotAfter)"
    #endregion Validate Certificate

    if ($UseStaging) {
        Write-Log -Message "STAGING MODE - Validation only. No CMG changes will be made."
        Write-Verbose -Message "Thumbprint : $LatestCertThumbprint"
        Write-Verbose -Message "Subject    : $($cert.Subject)"
        Write-Verbose -Message "NotAfter   : $($cert.NotAfter)"
        Write-Verbose -Message "DNS Names  : $($cert.DnsNameList.Unicode -join ', ')"
        Write-Log -Message "========== Set-CMCMGCert.ps1 Completed (Staging) =========="
        return
    }

    #region Export PFX with Ephemeral Password
    $tempDir = Join-Path -Path $PSScriptRoot -ChildPath "..\Temp"
    if (-not (Test-Path -Path $tempDir)) {
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    }
    $pfxOutputPath = Join-Path -Path $tempDir -ChildPath "CMG-Cert.pfx"
    $pfxPassword   = ConvertTo-SecureString -String ([System.Guid]::NewGuid().ToString()) -AsPlainText -Force
    Write-Log -Message "Exporting certificate to PFX: $pfxOutputPath"
    try {
        Export-PfxCertificate -Cert $cert -FilePath $pfxOutputPath -Password $pfxPassword -Force -ErrorAction Stop | Out-Null
        Write-Log -Message "Certificate exported to PFX successfully"
    }
    catch {
        Write-Log -Message "Failed to export certificate to PFX: $_" -Level "ERROR"
        throw
    }
    #endregion Export PFX with Ephemeral Password

    #region Import ConfigMgr Module
    Write-Log -Message "Starting ConfigMgr module initialization"
    if (-not $env:SMS_ADMIN_UI_PATH) {
        Write-Log -Message "SMS_ADMIN_UI_PATH environment variable not set. Ensure the ConfigMgr console is installed." -Level "ERROR"
        throw "SMS_ADMIN_UI_PATH environment variable not set. Ensure the ConfigMgr console is installed."
    }
    Write-Log -Message "SMS_ADMIN_UI_PATH detected: $env:SMS_ADMIN_UI_PATH"

    $configModulePath = Join-Path -Path $env:SMS_ADMIN_UI_PATH -ChildPath "..\ConfigurationManager.psd1"
    Write-Log -Message "Resolved Configuration Manager module path: $configModulePath"
    if (-not (Test-Path -Path $configModulePath)) {
        Write-Log -Message "Configuration Manager module not found at $configModulePath" -Level "ERROR"
        throw "Configuration Manager module not found at $configModulePath"
    }

    try {
        Write-Log -Message "Importing Configuration Manager module (non-interactive mode)"
        Import-Module -Name $configModulePath -DisableNameChecking -Force -ErrorAction Stop

        if (-not (Get-Command -Name Set-CMCloudManagementGateway -ErrorAction SilentlyContinue)) {
            throw "ConfigMgr module imported but Set-CMCloudManagementGateway command is not available"
        }
        Write-Log -Message "Configuration Manager module imported"
    }
    catch {
        Write-Log -Message "Failed to import Configuration Manager module: $_" -Level "ERROR"
        throw
    }
    #endregion Import ConfigMgr Module

    #region Update CMG Certificate
    $siteDrive = "$($config.SiteCode):"
    try {
        Write-Log -Message "Switching location to site drive: $siteDrive"
        Push-Location -Path $siteDrive -ErrorAction Stop
        Write-Log -Message "Pushed location to site drive: $siteDrive"
    }
    catch {
        Write-Log -Message "Failed to set location to site drive $siteDrive : $_" -Level "ERROR"
        throw
    }

    try {
        Write-Log -Message "Updating CMG service certificate for $($config.Name)"
        Set-CMCloudManagementGateway -Name $config.Name -ServiceCertPath $pfxOutputPath -ServiceCertPassword $pfxPassword -ErrorAction Stop
        Write-Log -Message "CMG service certificate updated successfully"
    }
    catch {
        Write-Log -Message "Failed to update CMG service certificate: $_" -Level "ERROR"
        throw
    }
    finally {
        Pop-Location
        Write-Log -Message "Restored previous location"
        Remove-Item -Path $pfxOutputPath -Force -ErrorAction SilentlyContinue
        Write-Log -Message "Ephemeral PFX removed"
    }
    #endregion Update CMG Certificate

    Write-Log -Message "========== Set-CMCMGCert.ps1 Completed Successfully =========="
    Write-Verbose -Message "CMG certificate deployment completed successfully for $($config.Name)"

# SIG # Begin signature block
# MIIfCAYJKoZIhvcNAQcCoIIe+TCCHvUCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUHyoHQEttjTaUh9cxOgT+M4kk
# DAigghk5MIIGFDCCA/ygAwIBAgIQeiOu2lNplg+RyD5c9MfjPzANBgkqhkiG9w0B
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
# DAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQUKSRJQpkiCDG8aHgY5j9Jg5pv
# deswDQYJKoZIhvcNAQEBBQAEggEAEYRM/ygryhRrKr8vXcPG7XyY3CvbWeHxVaUw
# 46J6rCcbs/7294O29AsZRiOz7JB+kAbOhhrRPD+tFs8HS6/Ww9nFB/tzd1mwFQWd
# V1qqHPX9DH8wronSt6q/3FoEsr2HUB9FWvvJ2WRRGFfQNem/P5/ZnAML6IQj1k0v
# aejz0acfwN4aTUY+4Hp4on38skSlPEkW3N7TZFuALZRQyOGD8QVC9uZdZW4cRL5I
# WupzMXLUIPqgKSRw5nA5PR93ACjQHWdMQX7HDB8NUuDB+Vg+Z7WllTpPxu2lZxVL
# EQ2c6WaDdu5dsOnsifpr7ekP86whNWzH3Uf53zVakOXpUigFCKGCAyMwggMfBgkq
# hkiG9w0BCQYxggMQMIIDDAIBATBqMFUxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9T
# ZWN0aWdvIExpbWl0ZWQxLDAqBgNVBAMTI1NlY3RpZ28gUHVibGljIFRpbWUgU3Rh
# bXBpbmcgQ0EgUjM2AhEApCk7bh7d16c0CIetek63JDANBglghkgBZQMEAgIFAKB5
# MBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDQy
# NDE3NDU1OVowPwYJKoZIhvcNAQkEMTIEMPMOkGWNxL/mGlj5WJDaf2xzO+/SyGSH
# DXKYtbhKdcKZHGOQq2X/fFSTQsQZEUU1CDANBgkqhkiG9w0BAQEFAASCAgCg/Ahy
# UP0TOe2IMiRVGJXpqVlGQ/2Ax1tu23yJwiDERJrsam1LEkKkPvDmmcIrYp8Ncmie
# OBUqgeI0dUUzBmWcPCF84S4TjJV6uwvNpVaW7FpW8qmSNxw2iI616JlOYtgPNgf1
# g0fU3heD912rAP5nlXrt7rCYGZN7SqlInKI0qel9lNU4k29cCSQ2ZRRGD5+SfQum
# Rp9vp3m1bE8MWVvh/q0UpMyadOtDjprPu9eWu7RL38r5umz470zMyftbKNspSA+i
# apCBLJLlCBB1fXSpA/JH75+LYgz5A+VIqj3tBjxQ87tZ6efJ9Dzl0OsIqkSS1xIp
# 29Bjg+YJDMUYmD26ggpwtLNh6r/Bl0WVH/yCQvcfggwGiYJYNwHJayVNPfPEldZS
# V9k72UlbPnAELNamUL7Ibi6CqGUKCDpTi80Qcqp79puMJ7vxw5rJ6bwNRi5yiNls
# z6LVb65z1oY7r2Iyg01pZkekS1HQm1TjRKJV5LKoy9Va60A3UKdIkWwD0KHfXFEp
# sjh8NYYFqzjF7l9phfs+ywrg3Uz5etmRenjfHg/hDWhj3rELpIdwPTb5cVdQFQRf
# F1VZjY8FNW82wr9ysIZQfPeJzwES82VeIKEcrephn5xtve2fQFCL3PEWTVaHsGty
# Zz+Bt4bIC831E59akfw5wXGQ4opnLd12YatE7A==
# SIG # End signature block
