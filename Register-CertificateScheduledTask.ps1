<##
.SYNOPSIS
    Registers a daily scheduled task to run Update-Certificate.ps1 for automated certificate renewal.

.DESCRIPTION
    This script sets up a Windows Scheduled Task that runs Update-Certificate.ps1 as SYSTEM with highest privileges.
    It can pull defaults from Vars.psd1 (PostScript, UseStaging, CertDomains) and accepts overrides via parameters.
    The task runs daily at 2 AM with an optional random delay to stagger requests across hosts.

.PARAMETER MainDomain
    Optional. Primary domain used to name the scheduled task. Falls back to the first CertDomains entry in Vars.psd1 when not provided.

.PARAMETER PostScript
    Required unless present in Vars.psd1. Path to the post-action script that will receive the latest certificate thumbprint.

.PARAMETER RandomDelay
    Optional. TimeSpan random delay applied to the 2 AM trigger (default 30 minutes) to reduce simultaneous executions.
    Can be configured in Vars.psd1 as an integer (minutes) or passed as a TimeSpan parameter.

.PARAMETER InitialDelay
    Optional. TimeSpan delay before the first one-time execution (default 5 minutes). Allows immediate certificate issuance without waiting until 2 AM.
    Can be configured in Vars.psd1 as an integer (minutes) or passed as a TimeSpan parameter.

.PARAMETER UseStaging
    Optional. Switch to configure the task to run Update-Certificate.ps1 against Let's Encrypt staging. Staging issues a fresh cert each run.

.PARAMETER KeepSecrets
    Optional. Switch to prevent deletion of generated secret files (useful for debugging).

.EXAMPLE
    .\Register-CertificateScheduledTask.ps1 -PostScript "Set-ADFSCert.ps1" -UseStaging -Verbose
    Creates the scheduled task using staging ACME, pulling MainDomain from Vars.psd1 if not specified.

.NOTES
    Runs as NT AUTHORITY\SYSTEM. Task path: \Cascade Technology Alliance. Trigger: daily 2 AM with configurable random delay.
##>
[CmdletBinding()]
param (
    [System.String]$MainDomain,
    [System.String]$PostScript,
    [TimeSpan]$RandomDelay = (New-TimeSpan -Minutes 30),
    [TimeSpan]$InitialDelay = (New-TimeSpan -Minutes 5),
    [Switch]$UseStaging,
    [Switch]$KeepSecrets
)

begin {
    $script:ScriptName = $MyInvocation.MyCommand.Name
    $script:LogDir = Join-Path -Path $PSScriptRoot -ChildPath "Logs"
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

    function script:Get-ConfiguredPostScripts {
        param(
            [Parameter()][hashtable]$VariablesData,
            [Parameter()][string]$PostScript,
            [Parameter(Mandatory = $true)][hashtable]$BoundParameters
        )

        $targets = @()

        if ($BoundParameters.ContainsKey('PostScript')) {
            return @(@{ Script = $PostScript; IsPrimary = $true; Source = 'Parameter' })
        }

        if (-not $VariablesData) {
            return $targets
        }

        $primaryPostScript = $null
        if ($VariablesData.ContainsKey('PostScript') -and -not [string]::IsNullOrWhiteSpace([string]$VariablesData['PostScript'])) {
            $primaryPostScript = [string]$VariablesData['PostScript']
            $targets += @{ Script = $primaryPostScript; IsPrimary = $true; Source = 'Vars.PostScript' }
        }
        elseif ($VariablesData.ContainsKey('PostScript(0)') -and -not [string]::IsNullOrWhiteSpace([string]$VariablesData['PostScript(0)'])) {
            $primaryPostScript = [string]$VariablesData['PostScript(0)']
            $targets += @{ Script = $primaryPostScript; IsPrimary = $true; Source = 'Vars.PostScript(0)' }
        }

        $numberedPostScriptKeys = $VariablesData.Keys |
            Where-Object -FilterScript { $_ -match '^PostScript\d+$' } |
            Sort-Object -Property { [int]($_ -replace '^PostScript', '') }

        foreach ($key in $numberedPostScriptKeys) {
            $value = [string]$VariablesData[$key]
            if ([string]::IsNullOrWhiteSpace($value)) {
                continue
            }
            $targets += @{ Script = $value; IsPrimary = $false; Source = "Vars.$key" }
        }

        return $targets
    }

    function script:Get-PostScriptFromTaskArguments {
        param(
            [Parameter()][string]$Arguments
        )

        if ([string]::IsNullOrWhiteSpace($Arguments)) {
            return $null
        }

        $match = [regex]::Match($Arguments, '-PostScript\s+"([^"]+)"')
        if ($match.Success -and $match.Groups.Count -ge 2) {
            return $match.Groups[1].Value
        }

        return $null
    }

    Write-Verbose -Message ("BEGIN: {0} starting" -f $MyInvocation.MyCommand.Name)
    Write-Log -Message "BEGIN: $script:ScriptName starting"
}

process {
    Write-Verbose -Message "PROCESS: No pipeline input to process."
}

end {
    Write-Log -Message "========== $script:ScriptName Started =========="

    #region Configuration
    # Import Vars.psd1 for configuration
    $VariablesDataPath = Join-Path -Path $PSScriptRoot -ChildPath "Vars.psd1"
    $VariablesData = $null
    if (Test-Path -Path $VariablesDataPath) {
        Write-Log -Message "Loading configuration from Vars.psd1"
        $VariablesData = Import-PowerShellDataFile -Path $VariablesDataPath
        
        # If PostScript not provided via parameter, use value from Vars.psd1
        if (-not $PSBoundParameters.ContainsKey('PostScript') -and $VariablesData.ContainsKey('PostScript')) {
            $PostScript = $VariablesData['PostScript']
            Write-Log -Message "Using PostScript from Vars.psd1: $PostScript"
            Write-Verbose -Message "Using PostScript from Vars.psd1: $PostScript"
        }
        
        # If UseStaging not provided via parameter, use value from Vars.psd1
        if (-not $PSBoundParameters.ContainsKey('UseStaging') -and $VariablesData.ContainsKey('UseStaging') -and $VariablesData['UseStaging']) {
            $UseStaging = $true
            Write-Log -Message "Using UseStaging from Vars.psd1: $UseStaging"
            Write-Verbose -Message "Using UseStaging from Vars.psd1: $UseStaging"
        }
        
        # If RandomDelay not provided via parameter, use value from Vars.psd1
        if (-not $PSBoundParameters.ContainsKey('RandomDelay') -and $VariablesData.ContainsKey('RandomDelay')) {
            $RandomDelay = New-TimeSpan -Minutes $VariablesData['RandomDelay']
            Write-Log -Message "Using RandomDelay from Vars.psd1: $RandomDelay"
            Write-Verbose -Message "Using RandomDelay from Vars.psd1: $RandomDelay"
        }
        
        # If InitialDelay not provided via parameter, use value from Vars.psd1
        if (-not $PSBoundParameters.ContainsKey('InitialDelay') -and $VariablesData.ContainsKey('InitialDelay')) {
            $InitialDelay = New-TimeSpan -Minutes $VariablesData['InitialDelay']
            Write-Log -Message "Using InitialDelay from Vars.psd1: $InitialDelay"
            Write-Verbose -Message "Using InitialDelay from Vars.psd1: $InitialDelay"
        }
        
        # If KeepSecrets not provided via parameter, use value from Vars.psd1
        if (-not $PSBoundParameters.ContainsKey('KeepSecrets') -and $VariablesData.ContainsKey('KeepSecrets') -and $VariablesData['KeepSecrets']) {
            $KeepSecrets = $true
            Write-Log -Message "Using KeepSecrets from Vars.psd1: $KeepSecrets"
            Write-Verbose -Message "Using KeepSecrets from Vars.psd1: $KeepSecrets"
        }
        
        # If MainDomain not provided, derive it from CertDomains in Vars.psd1
        if (-not $PSBoundParameters.ContainsKey('MainDomain') -and $VariablesData.ContainsKey('CertDomains')) {
            $certDomains = $VariablesData['CertDomains']
            if ($certDomains -is [System.Array]) {
                $MainDomain = $certDomains[0]
            }
            else {
                $MainDomain = ($certDomains -split ',')[0]
            }
            Write-Log -Message "Using MainDomain from Vars.psd1: $MainDomain"
            Write-Verbose -Message "Using MainDomain from Vars.psd1: $MainDomain"
        }
    }
    else {
        Write-Log -Message "Vars.psd1 not found at $VariablesDataPath; using parameter values only" -Level "WARN"
    }

    #endregion Configuration

    #region Scheduled Task Registration
    $configuredPostScripts = Get-ConfiguredPostScripts -VariablesData $VariablesData -PostScript $PostScript -BoundParameters $PSBoundParameters

    if (-not $configuredPostScripts -or $configuredPostScripts.Count -eq 0) {
        Write-Log -Message "PostScript is required but not provided" -Level "ERROR"
        throw "PostScript is required. Provide it via -PostScript parameter, Vars.psd1 PostScript, or Vars.psd1 PostScript(0)."
    }

    $hasSecondaryPostScripts = ($configuredPostScripts | Where-Object -FilterScript { -not $_.IsPrimary }).Count -gt 0
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Update-Certificate.ps1'
    $secondaryOffsetHours = 0

    foreach ($target in $configuredPostScripts) {
        $scriptValue = $target.Script
        $taskName = "Renew-Certificates-$MainDomain"
        $offsetHours = 0
        if ($hasSecondaryPostScripts -and -not $target.IsPrimary) {
            $secondaryOffsetHours++
            $offsetHours = $secondaryOffsetHours
            $postScriptBaseName = [System.IO.Path]::GetFileNameWithoutExtension($scriptValue)
            $taskName = "Renew-Certificates-$MainDomain-$postScriptBaseName"
        }

        Write-Log -Message "Scheduled task target name: $taskName (PostScript source: $($target.Source), script: $scriptValue)"

        $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            Write-Log -Message "Scheduled task $taskName already exists"
            Write-Verbose -Message "Scheduled task $taskName already exists."

            $taskAction = $null
            if ($existingTask.Actions -and $existingTask.Actions.Count -gt 0) {
                $taskAction = $existingTask.Actions[0]
            }

            if (-not $taskAction) {
                Write-Log -Message "Scheduled task $taskName has no action to validate against expected PostScript '$scriptValue'" -Level "WARN"
                Write-Verbose -Message "Scheduled task $taskName has no action. Expected PostScript from Vars/parameters: $scriptValue"
                continue
            }

            $configuredPostScript = Get-PostScriptFromTaskArguments -Arguments $taskAction.Arguments
            if ([string]::IsNullOrWhiteSpace($configuredPostScript)) {
                Write-Log -Message "Scheduled task $taskName action could not be parsed for -PostScript. Expected '$scriptValue'. Action arguments: $($taskAction.Arguments)" -Level "WARN"
                Write-Verbose -Message "Scheduled task $taskName action is missing or unparseable -PostScript; expected $scriptValue"
                continue
            }

            if ($configuredPostScript -ine $scriptValue) {
                Write-Log -Message "Scheduled task $taskName PostScript mismatch: expected '$scriptValue' from Vars/parameters, found '$configuredPostScript'. Task was not modified automatically." -Level "WARN"
                Write-Verbose -Message "Scheduled task $taskName mismatch with Vars setup. Expected: $scriptValue | Found: $configuredPostScript"
            }
            else {
                Write-Log -Message "Scheduled task $taskName PostScript validation passed: $configuredPostScript"
            }
            continue
        }

        Write-Log -Message "Scheduled task $taskName does not exist. Creating..."
        Write-Verbose -Message "Scheduled task $taskName does not exist. Creating..."

        $ArgumentList = "-File `\"$scriptPath`\" -PostScript `\"$scriptValue`\""
        if ($UseStaging) {
            $ArgumentList += " -UseStaging"
        }
        if ($KeepSecrets) {
            $ArgumentList += " -KeepSecrets"
        }
        Write-Log -Message "Scheduled task action: PowerShell.exe $ArgumentList"

        # Create triggers: one-time run after InitialDelay (+offset for additional post-scripts), then daily at 2 AM (+offset)
        $Action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument $ArgumentList -WorkingDirectory $PSScriptRoot
        $initialRunAt = (Get-Date).Add($InitialDelay).AddHours($offsetHours)
        $dailyRunAt = (Get-Date).Date.AddHours(2 + $offsetHours)
        $TriggerOnce = New-ScheduledTaskTrigger -Once -At $initialRunAt
        $TriggerDaily = New-ScheduledTaskTrigger -At $dailyRunAt -Daily -RandomDelay $RandomDelay
        $Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -RunLevel Highest
        $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -TaskPath "\Cascade Technology Alliance" -Action $Action -Trigger @($TriggerOnce, $TriggerDaily) -Principal $Principal -Settings $Settings
        Write-Log -Message "Scheduled task $taskName created successfully. Initial run: $initialRunAt; Daily run: $($dailyRunAt.ToString('HH:mm')) with random delay $RandomDelay; OffsetHours=$offsetHours"
        Write-Verbose -Message "Scheduled task $taskName created with initial run at $initialRunAt and daily at $($dailyRunAt.ToString('HH:mm')) (offset hours: $offsetHours)."
    }

    #endregion Scheduled Task Registration
    Write-Log -Message "========== $script:ScriptName Completed =========="
}



# SIG # Begin signature block
# MIIfCAYJKoZIhvcNAQcCoIIe+TCCHvUCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU0RgN4r+pFn9tgnUA5yt+84+6
# 3/Ogghk5MIIGFDCCA/ygAwIBAgIQeiOu2lNplg+RyD5c9MfjPzANBgkqhkiG9w0B
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
# DAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQUwMD/yLuzuuQMPuk5Qr+eMMVG
# QTcwDQYJKoZIhvcNAQEBBQAEggEAGY3s3OylrfRMuqBfNodAhZhWW7DmECDzZIyW
# 37r/u2jZoECruDa7YiTTc67r5ggzCDbOd/7qiyFIvXLlS1ZQzsd/RJsJISIFGdBf
# AUFv4N7FBcVK3Bc40yIBqEgqSjjCm92lV0Rx1Ap8JOkWldxjKTSez4a9NF8cZ7Lh
# 9m78PxjWnz6WMdaSz5/uBnBfDP7fzRD/EdjrsJeYQTI+d5zgi+rYmSON3jNxvDSb
# Jh5HT/gysfZyOS9DhsE5WGFTLqNrQQKRw1Ix9GG8g1d0xqKFE1fmntUCBVfs7Jyo
# Vu5yYf42FJgezQVoHVOwvDDNzn3tifNH9RfQAkmF2Ow2MV+TEaGCAyMwggMfBgkq
# hkiG9w0BCQYxggMQMIIDDAIBATBqMFUxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9T
# ZWN0aWdvIExpbWl0ZWQxLDAqBgNVBAMTI1NlY3RpZ28gUHVibGljIFRpbWUgU3Rh
# bXBpbmcgQ0EgUjM2AhEApCk7bh7d16c0CIetek63JDANBglghkgBZQMEAgIFAKB5
# MBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDQy
# NDE3NDYxN1owPwYJKoZIhvcNAQkEMTIEMM/rnxBQtII/GxW0qIakpk3j9/4hzjW7
# LTyxL506lgWSnGCB5CLdUWfx/2CJrWT1KDANBgkqhkiG9w0BAQEFAASCAgAUCLxW
# XhzELOkipwu60zk8q6lhBLIhmpgwvOqBPsZinhELOy82OFLHF5GlK8xIDnhKgDBE
# RxIAB0HHKdQLQqMhwNiFKBkixFjXqGs7bdqtSQOkKP68ll/Z7GgzlK7FEiC4a5G/
# vKqdaa54ZEKxTjL6h9j9VFGjAYweRICq+1E6E1+1GzNyEbHQRxNJjEhBb8CtoSY8
# oNP5btHc4tIrD8i/k/OglqtrpAxRn0/9wux/61dDRlsEA6ysgDLtcEo3uLadYdsM
# njduKR+DJN+o9FGHrTD9FhyjpkSvk89Pc9xE2t5zsLNnuhaFcAvJAQbiAv6/iqRn
# ug7IauMwxvWYHb0VOWnwLc6eL3cZJxC5uEZO8jUNW464wBsJSx2Bpdp77u+cGHwa
# Vaew1lC8cPeVgI9NEBg75NDbzr/fGtmAm0Z1OlPXZpow58CSeRwvJYZzNkb4niTh
# I0gtoAcIhcXWY3ynErRwZBxwHYXEuJP1++5fZWZXrRG/d07+vH7Iwm8A41Ng8fs2
# rVBFLZBTGJCoIfgnncxwAF8enP5IN6QY3W0dY1fARXF8EqbkevfJbsmrIKYKDspM
# kloSjS3WHZqJ/8j4lkW4xZk63sqSC48IQQwdfd+6ntw5zilhjrrZLiUXyzy46C2Q
# 3rpmupvLHtAvPUwjbaOXMmMkMqHnuP3zKr8Wbg==
# SIG # End signature block
