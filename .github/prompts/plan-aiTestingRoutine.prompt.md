# Plan: AI Testing Routine for PSLECertManager Scripts

## Overview
Comprehensive testing protocol for validating script functionality after human or AI patches. Ensures all certificate management workflows remain operational, non-breaking, and compliant with security requirements.

## Pre-Test Requirements

### Environment Setup
1. **PowerShell Version**: Test on both PS 5.1 (Windows) and PS 7+ (cross-platform)
2. **Posh-ACME Module**: Version 4.28.0 installed
3. **Test Account**: SYSTEM account context (use `psexec -i -s powershell.exe` for simulation)
4. **Directories**:
   - AppData: `C:\Windows\System32\config\systemprofile\AppData\Local\Posh-ACME\` (Windows SYSTEM)
   - Logs: `$PSScriptRoot\Logs\` writable
5. **Configuration Files**:
   - `Vars.psd1` populated with test domains
   - `Vars.psd1.example` exists as template
   - `Secret.psd1` available (or mock for syntax tests)
   - `BitWardenSecrets.psd1` structure validated

### Safety Checks
- [ ] Backup current certificates before testing
- [ ] Use staging ACME servers (`-UseStaging` flag) for all tests
- [ ] Verify no production domains in test config
- [ ] Confirm rollback plan for failed tests

---

## Test Suite 1: Update-Certificate.ps1 (Core Script)

### 1.1 Syntax and Load Tests
**Purpose**: Verify script loads without errors and parameters are valid.

**Commands**:
```powershell
# Syntax validation
$errors = $null
$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content ./Update-Certificate.ps1 -Raw), [ref]$errors)
if ($errors.Count -gt 0) { Write-Error "Syntax errors detected: $errors" }

# Parameter validation
Get-Help ./Update-Certificate.ps1 -Full
```

**Expected**:
- ✅ Zero syntax errors
- ✅ Help shows `-UseStaging` switch parameter
- ✅ No required parameters (all optional with defaults)

### 1.2 Dry Run: Staging Mode (New Certificate)
**Purpose**: Force new certificate creation in staging to verify full workflow.

**Commands**:
```powershell
./Update-Certificate.ps1 -UseStaging
```

**Validation**:
- ✅ Log file created at `Logs/Update-Certificate.log`
- ✅ `Invoke-SecretFile.ps1` executed (Secret.psd1 generated)
- ✅ Posh-ACME initialized (order created in AppData)
- ✅ Certificate created with staging CA
- ✅ `$certificateUpdated` flag set to `$true`
- ✅ Post-script invoked with `-UseStaging $true`
- ✅ Exit code 0 (success)
- ✅ No plaintext credentials logged
- ✅ Log rotation triggered if file exceeds threshold

**Verify Log Contains**:
```
[INFO] Starting Update-Certificate.ps1
[INFO] Staging mode enabled
[INFO] Loading secrets from Secret.psd1
[INFO] Checking certificate status
[INFO] Certificate created successfully
[INFO] Invoking post-script: Set-ADFSCert.ps1 (or configured script)
[INFO] Certificate update completed
```

### 1.3 Dry Run: Renewal Check (No Action)
**Purpose**: Verify renewal logic correctly identifies no action needed.

**Commands**:
```powershell
# Run immediately after 1.2 (cert just created, no renewal needed)
./Update-Certificate.ps1 -UseStaging
```

**Validation**:
- ✅ Submit-Renewal returns "no renewal needed"
- ✅ `$certificateUpdated` remains `$false`
- ✅ Post-script NOT invoked
- ✅ Log shows "Certificate is valid, no renewal needed"
- ✅ Secrets NOT reloaded (lazy loading working)

### 1.4 Force New Certificate in Staging
**Purpose**: Confirm staging mode always forces new cert with `-Force` flag.

**Commands**:
```powershell
./Update-Certificate.ps1 -UseStaging
```

**Validation**:
- ✅ `New-PACertificate` called with `-Force` parameter
- ✅ New order created despite existing valid cert
- ✅ Post-script invoked

### 1.5 Log Rotation Test
**Purpose**: Verify log cap and rotation at 1MB threshold.

**Commands**:
```powershell
# Simulate log growth by appending large content
1..50000 | ForEach-Object { 
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO] Test log entry number $_" | Add-Content ./Logs/Update-Certificate.log 
}

# Run script to trigger rotation
./Update-Certificate.ps1 -UseStaging
```

**Validation**:
- ✅ Log file size never exceeds 1MB
- ✅ Rotated files created: `Update-Certificate.log.1` through `.log.5`
- ✅ Oldest rotations (>90 days) purged
- ✅ Maximum 5 rotation files maintained
- ✅ Rotation marker logged: "--- Log rotated from previous file ---"
- ✅ New entries append to fresh log

### 1.6 Error Handling Tests
**Purpose**: Verify graceful failure with informative errors.

**Test Cases**:
```powershell
# Missing Vars.psd1
Rename-Item Vars.psd1 Vars.psd1.bak
./Update-Certificate.ps1
# Expected: Error logged, exit code non-zero, Vars.psd1.bak restored

# Invalid domain format
# Edit Vars.psd1: $domains = @('invalid domain name!')
./Update-Certificate.ps1 -UseStaging
# Expected: Posh-ACME validation error logged

# Missing post-script
# Edit Vars.psd1: $postActionScript = 'NonExistent.ps1'
./Update-Certificate.ps1 -UseStaging
# Expected: Warning logged, script continues (or errors based on implementation)
```

**Validation**:
- ✅ All errors logged with `[ERROR]` prefix
- ✅ Non-zero exit codes on failure
- ✅ Signature block remains intact after errors
- ✅ No partial state (cert half-created)

---

## Test Suite 2: Invoke-SecretFile.ps1

### 2.1 Secret Generation Test
**Purpose**: Verify BitWarden secrets converted to Secret.psd1.

**Commands**:
```powershell
./Invoke-SecretFile.ps1
```

**Validation**:
- ✅ `Secret.psd1` created in script root
- ✅ Contains `$email`, `$R53AccessKey`, `$R53SecretKey` variables
- ✅ Values match BitWardenSecrets.psd1 sources
- ✅ No plaintext secrets in Invoke-SecretFile.ps1 (uses bws.exe)
- ✅ Proper PowerShell hashtable syntax

### 2.2 Idempotency Test
**Purpose**: Confirm multiple runs produce consistent output.

**Commands**:
```powershell
./Invoke-SecretFile.ps1
$hash1 = Get-FileHash Secret.psd1
Start-Sleep -Seconds 2
./Invoke-SecretFile.ps1
$hash2 = Get-FileHash Secret.psd1
$hash1.Hash -eq $hash2.Hash
```

**Validation**:
- ✅ Hashes match (deterministic output)
- ✅ No duplicate entries

---

## Test Suite 3: Post-Action Scripts

### 3.1 Set-ADFSCert.ps1 (ADFS Certificate Update)
**Purpose**: Validate ADFS certificate deployment in staging mode.

**Commands**:
```powershell
./Set-ADFSCert.ps1 -CertThumbprint <staging-cert-thumbprint> -UseStaging $true
```

**Validation**:
- ✅ Script accepts staging flag
- ✅ Locates certificate by thumbprint in staging store
- ✅ Logs actions taken (actual ADFS updates skipped in staging)
- ✅ Returns successfully without modifying production ADFS

### 3.2 Set-WAPCert.ps1 (Web Application Proxy)
**Purpose**: Validate WAP certificate deployment.

**Commands**:
```powershell
./Set-WAPCert.ps1 -CertThumbprint <staging-cert-thumbprint> -UseStaging $true
```

**Validation**:
- ✅ Staging mode honored
- ✅ Certificate validated
- ✅ No production WAP changes

### 3.3 Set-CMCMGCert.ps1 (Configuration Manager Cloud Gateway)
**Purpose**: Validate CMG certificate deployment.

**Commands**:
```powershell
./Set-CMCMGCert.ps1 -CertThumbprint <staging-cert-thumbprint> -UseStaging $true
```

**Validation**:
- ✅ Staging mode honored
- ✅ Certificate validated
- ✅ No production CMG changes

---

## Test Suite 4: Integration Tests

### 4.1 End-to-End Workflow (Staging)
**Purpose**: Full certificate lifecycle from request to deployment.

**Commands**:
```powershell
# Clean slate
Remove-Item ./Logs/* -Force -ErrorAction SilentlyContinue
Remove-Item $env:LOCALAPPDATA/Posh-ACME/* -Recurse -Force -ErrorAction SilentlyContinue

# Run full workflow
./Update-Certificate.ps1 -UseStaging
```

**Validation**:
- ✅ Secrets loaded
- ✅ Posh-ACME initialized
- ✅ Certificate ordered and validated
- ✅ Certificate stored in correct location
- ✅ Post-script invoked with correct thumbprint
- ✅ Log entries show complete workflow
- ✅ Exit code 0

### 4.2 Scheduled Task Simulation
**Purpose**: Verify script runs as SYSTEM account via scheduled task.

**Commands**:
```powershell
# Run as SYSTEM (requires PsExec or scheduled task)
PsExec.exe -i -s powershell.exe -Command "cd C:\Path\To\PSLECertManager; .\Update-Certificate.ps1 -UseStaging"
```

**Validation**:
- ✅ Script executes without interactive prompts
- ✅ Logs written to correct location
- ✅ Posh-ACME uses SYSTEM AppData path
- ✅ No credential prompts
- ✅ Post-script executes successfully

### 4.3 Concurrent Execution Test
**Purpose**: Verify no race conditions if script runs overlapping.

**Commands**:
```powershell
# Start two instances
Start-Job -ScriptBlock { ./Update-Certificate.ps1 -UseStaging }
Start-Sleep -Milliseconds 100
Start-Job -ScriptBlock { ./Update-Certificate.ps1 -UseStaging }
Get-Job | Wait-Job | Receive-Job
```

**Validation**:
- ✅ No file lock errors
- ✅ Both executions complete
- ✅ Logs interleaved correctly (or second execution detects lock)

---

## Test Suite 5: Regression Tests (Post-Patch)

### 5.1 Signature Block Integrity
**Purpose**: Ensure code signing block remains untouched.

**Commands**:
```powershell
Get-Content ./Update-Certificate.ps1 -Tail 20
```

**Validation**:
- ✅ Signature block present at end of file
- ✅ No extra newlines or characters after signature
- ✅ `# SIG # Begin signature block` and `# SIG # End signature block` intact

### 5.2 Backward Compatibility (Parameters)
**Purpose**: Confirm no breaking changes to parameters.

**Commands**:
```powershell
# Test legacy invocation (if previously parameterless)
./Update-Certificate.ps1

# Test with all known parameters
./Update-Certificate.ps1 -UseStaging
```

**Validation**:
- ✅ All previous invocations still work
- ✅ No new required parameters added
- ✅ Default behavior unchanged (unless intentionally modified)

### 5.3 Output Format Validation
**Purpose**: Ensure log format and exit codes unchanged.

**Commands**:
```powershell
./Update-Certificate.ps1 -UseStaging
$exitCode = $LASTEXITCODE
Get-Content ./Logs/Update-Certificate.log | Select-String -Pattern "^\[.*?\] \[(INFO|WARNING|ERROR)\]"
```

**Validation**:
- ✅ Log entries match pattern: `[YYYY-MM-DD HH:mm:ss] [LEVEL] Message`
- ✅ Exit code 0 on success, non-zero on failure
- ✅ No unexpected output to console (all output in logs)

---

## Test Suite 6: Security Validation

### 6.1 Secret Exposure Test
**Purpose**: Ensure no secrets logged or displayed.

**Commands**:
```powershell
./Update-Certificate.ps1 -UseStaging -Verbose
Get-Content ./Logs/Update-Certificate.log | Select-String -Pattern "AKIA|SecretKey|password"
```

**Validation**:
- ✅ No AWS keys in logs
- ✅ No passwords in logs
- ✅ No BitWarden secrets in logs
- ✅ Certificate private keys not exposed

### 6.2 File Permissions Test
**Purpose**: Verify sensitive files have restricted access.

**Commands**:
```powershell
(Get-Acl ./Secret.psd1).Access | Format-Table IdentityReference, FileSystemRights
```

**Validation**:
- ✅ Secret.psd1 readable only by SYSTEM/Administrators
- ✅ BitWardenSecrets.psd1 restricted
- ✅ Logs directory writable by script account

---

## Automated Test Execution

### Quick Test Script
```powershell
# Run all critical tests
$tests = @(
    @{ Name = "Syntax Check"; Script = { (([System.Management.Automation.PSParser]::Tokenize((Get-Content ./Update-Certificate.ps1 -Raw), [ref]$null)).Count -gt 0) } }
    @{ Name = "Staging Run"; Script = { ./Update-Certificate.ps1 -UseStaging; $? } }
    @{ Name = "Log Exists"; Script = { Test-Path ./Logs/Update-Certificate.log } }
    @{ Name = "No Secrets Logged"; Script = { -not (Get-Content ./Logs/Update-Certificate.log | Select-String "AKIA") } }
)

foreach ($test in $tests) {
    try {
        $result = & $test.Script
        $status = if ($result) { "✅ PASS" } else { "❌ FAIL" }
    } catch {
        $status = "❌ ERROR: $_"
    }
    Write-Host "$($test.Name): $status"
}
```

---

## Post-Test Cleanup

### Manual Cleanup
```powershell
# Remove staging certificates
Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Issuer -like "*Fake LE*" } | Remove-Item

# Clear logs
Remove-Item ./Logs/*.log* -Force

# Reset Posh-ACME
Remove-Item $env:LOCALAPPDATA/Posh-ACME/* -Recurse -Force
```

### Restore Production State
- [ ] Restore `Vars.psd1` if modified
- [ ] Restore `Secret.psd1` if modified
- [ ] Verify production scheduled task unchanged
- [ ] Confirm no staging certificates in production stores

---

## AI Testing Protocol

### When to Run Tests
1. **Before committing code**: Run Test Suites 1-3 (core functionality)
2. **After human patch**: Run full Test Suite 1-6
3. **After AI patch**: Run Test Suite 5 (regression) + Suite 1.1-1.4 (core)
4. **Before production deployment**: Run Suite 4 (integration) + Suite 6 (security)

### Pass/Fail Criteria
- ✅ **PASS**: All validation checkmarks met, exit code 0, logs clean
- ⚠️ **WARN**: Non-critical failures (e.g., log rotation timing), script functional
- ❌ **FAIL**: Syntax errors, certificate creation failed, secrets exposed, signature broken

### Automated vs Manual
- **Automated**: Syntax checks, staging runs, log validation, secret scanning
- **Manual**: SYSTEM account testing, scheduled task validation, production rollback

---

## Change Log Validation

### After Each Patch
Document in commit message or changelog:
- [ ] Test suites executed (by number)
- [ ] Pass/fail status for each suite
- [ ] Any warnings or edge cases observed
- [ ] PowerShell versions tested (5.1, 7.x)
- [ ] Execution environment (user context vs SYSTEM)

**Example**:
```
✅ Test Suite 1: Update-Certificate.ps1 - PASS (PS 7.4)
✅ Test Suite 2: Invoke-SecretFile.ps1 - PASS
✅ Test Suite 5: Regression Tests - PASS
⚠️ Test Suite 4.3: Concurrent execution - WARN (expected lock behavior)
```

---

## Notes for AI Agents
- Always run **Test Suite 1.1** (syntax) before any other tests
- Use `-UseStaging` for all tests to avoid production cert requests
- If a test fails, review logs first: `Get-Content ./Logs/Update-Certificate.log -Tail 50`
- Never commit code that fails Test Suite 5 (regression)
- Document any test modifications in this plan file
- Preserve signature block - verify with Test Suite 5.1 after every edit
