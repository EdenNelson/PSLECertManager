# SYSTEM Account Testing Plan for Certificate Automation

## Overview

This testing plan addresses the critical difference between manual testing (running as regular user) and production execution (running as SYSTEM via scheduled task).

## Problem Statement

**Key Issue:** Posh-ACME stores certificate data in the executing user's AppData directory. This creates separate data stores for:
- Regular users: `C:\Users\{username}\AppData\Local\Posh-ACME\`
- SYSTEM account: `C:\Windows\System32\config\systemprofile\AppData\Local\Posh-ACME\`

**Impact:** Certificates created during manual testing are NOT available to the scheduled task running as SYSTEM.

---

## Testing Phases

### Phase 1: Initial Development Testing (Current User)

**Purpose:** Validate script logic and configuration without SYSTEM complexity

**Prerequisites:**
- Administrative privileges
- BitWarden secrets configured
- AWS Route53 credentials in vault

**Steps:**
1. Create test configuration files (`Vars.psd1`, `BitWardenSecrets.psd1`)
2. Run `Invoke-SecretFile.ps1` to generate `Secret.psd1`
3. Execute `Update-Certificate.ps1 -PostScript "Set-ADFSCert.ps1" -Verbose`
4. Verify certificate creation in: `$env:LOCALAPPDATA\Posh-ACME\`
5. Validate post-script execution and ADFS certificate deployment

**Expected Results:**
- Certificate created successfully
- DNS-01 validation completes via Route53
- Certificate installed in local machine store
- ADFS certificates updated
- ADFS service restarts successfully

**Limitations:**
- Certificates stored in user's AppData (NOT production location)
- Does not test scheduled task execution
- Does not validate SYSTEM account permissions

---

### Phase 2: SYSTEM Account Testing (Production Environment)

**Purpose:** Validate production execution context and SYSTEM account data isolation

**Prerequisites:**
- Phase 1 completed successfully
- Sysinternals PsExec downloaded
- Administrative privileges

**Setup:**
```powershell
# Download PsExec if not available
# https://docs.microsoft.com/en-us/sysinternals/downloads/psexec

# Launch PowerShell as SYSTEM account
PsExec.exe -s -i powershell.exe
```

**Steps:**

1. **Verify Execution Context**
   ```powershell
   # Confirm running as SYSTEM
   whoami
   # Should show: nt authority\system
   
   # Navigate to script directory
   cd C:\Scripts\Certificates  # Adjust path as needed
   ```

2. **Verify Posh-ACME Data Location**
   ```powershell
   # Check current Posh-ACME configuration directory
   Import-Module .\Posh-ACME\4.28.0\Posh-ACME.psm1
   Get-PAServer | Select-Object -ExpandProperty Folder
   
   # Expected output:
   # C:\Windows\System32\config\systemprofile\AppData\Local\Posh-ACME\acme-v02.api.letsencrypt.org
   ```

3. **Run Certificate Creation as SYSTEM**
   ```powershell
   # Execute main script
   .\Update-Certificate.ps1 -PostScript "Set-ADFSCert.ps1" -Verbose
   ```

4. **Verify Certificate Storage**
   ```powershell
   # Check SYSTEM's Posh-ACME directory
   $systemPoshAcme = "C:\Windows\System32\config\systemprofile\AppData\Local\Posh-ACME"
   Get-ChildItem -Path $systemPoshAcme -Recurse
   
   # List generated certificates
   Get-PACertificate | Format-List
   ```

5. **Verify Windows Certificate Store**
   ```powershell
   # Check Local Machine certificate store
   $certFriendlyName = "ADFS Let's Encrypt Certificate"  # From Vars.psd1
   Get-ChildItem Cert:\LocalMachine\My | Where-Object {$_.FriendlyName -match $certFriendlyName}
   ```

**Expected Results:**
- Script executes without errors
- Certificate created in SYSTEM's AppData location
- Certificate installed in Local Machine store
- ADFS certificates updated successfully
- ADFS service restarts

**Common Issues:**
- **BitWarden CLI access:** Ensure `bws.exe` can run as SYSTEM
- **File permissions:** SYSTEM must have read access to script files
- **Network access:** SYSTEM account can access internet (Route53, Let's Encrypt)

---

### Phase 3: Scheduled Task Validation

**Purpose:** Validate automated execution via Windows Task Scheduler

**Prerequisites:**
- Phase 2 completed successfully
- Scheduled task created via `Register-CertificateScheduledTask.ps1`

**Steps:**

1. **Create Scheduled Task**
   ```powershell
   # Run as administrator (not as SYSTEM)
   .\Register-CertificateScheduledTask.ps1 -MainDomain "example.cascadetech.org" -PostScript "Set-ADFSCert.ps1"
   ```

2. **Verify Task Configuration**
   ```powershell
   # Check task properties
   $taskName = "Renew-Certificates-example.cascadetech.org"
   Get-ScheduledTask -TaskName $taskName | Format-List *
   
   # Verify principal is SYSTEM
   $task = Get-ScheduledTask -TaskName $taskName
   $task.Principal.UserId
   # Should show: NT AUTHORITY\SYSTEM
   ```

3. **Manual Task Execution**
   ```powershell
   # Trigger task manually for immediate testing
   Start-ScheduledTask -TaskName $taskName
   
   # Monitor task status
   Get-ScheduledTaskInfo -TaskName $taskName
   ```

4. **Review Task History**
   ```powershell
   # Check task history in Event Viewer
   # Event Viewer > Applications and Services Logs > Microsoft > Windows > TaskScheduler > Operational
   
   # Or via PowerShell:
   Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -MaxEvents 20 |
       Where-Object {$_.Message -like "*$taskName*"}
   ```

5. **Verify Certificate Renewal**
   ```powershell
   # Run as SYSTEM to check Posh-ACME state
   PsExec.exe -s -i powershell.exe
   
   # In SYSTEM session:
   Import-Module C:\Scripts\Certificates\Posh-ACME\4.28.0\Posh-ACME.psm1
   Get-PACertificate | Format-List Subject, NotAfter, Status, RenewalWindow
   ```

**Expected Results:**
- Task executes on schedule (or manually triggered)
- Task completes successfully (exit code 0)
- Certificate renewed if within 30-day window
- ADFS certificates updated
- No errors in Task Scheduler event log

**Common Issues:**
- **Task runs but fails:** Check execution policy: `Get-ExecutionPolicy -Scope LocalMachine`
- **Script not found:** Verify working directory in task definition
- **Access denied:** Ensure SYSTEM has permissions to script directory

---

## Verification Checklist

### Pre-Production Validation

- [ ] Phase 1: Script executes successfully as regular user
- [ ] Phase 2: Script executes successfully as SYSTEM via PsExec
- [ ] Phase 3: Scheduled task created successfully
- [ ] Phase 3: Manual task execution completes without errors
- [ ] Certificate exists in SYSTEM's Posh-ACME directory
- [ ] Certificate installed in Local Machine store
- [ ] ADFS certificates updated correctly
- [ ] ADFS service restarts successfully
- [ ] Task Scheduler event log shows no errors

### Production Monitoring

- [ ] Task executes on schedule (check daily logs)
- [ ] Certificate renewal occurs within 30-day window
- [ ] Renewal events logged properly
- [ ] ADFS service availability maintained during renewal
- [ ] No certificate expiration alerts

---

## Rollback Plan

If SYSTEM account execution fails:

1. **Immediate Action:**
   ```powershell
   # Disable scheduled task
   Disable-ScheduledTask -TaskName "Renew-Certificates-example.cascadetech.org"
   ```

2. **Manual Certificate Creation:**
   ```powershell
   # Run as SYSTEM via PsExec
   PsExec.exe -s -i powershell.exe
   cd C:\Scripts\Certificates
   .\Update-Certificate.ps1 -PostScript "Set-ADFSCert.ps1" -Verbose
   ```

3. **Investigation:**
   - Review Task Scheduler operational log
   - Check SYSTEM account permissions on script directory
   - Verify BitWarden CLI accessibility from SYSTEM context
   - Test Route53 API access from SYSTEM account

---

## Key Learnings

1. **Account Isolation:** Windows user accounts maintain separate Posh-ACME data stores
2. **Testing Accuracy:** Production testing MUST use SYSTEM account context
3. **PsExec Usage:** Essential tool for SYSTEM account testing before scheduled deployment
4. **Data Location Verification:** Always verify Posh-ACME folder location matches execution account
5. **Scheduled Task Configuration:** Task must explicitly specify SYSTEM account principal

---

## Additional Resources

- [Posh-ACME Data Storage Locations](https://poshac.me/docs/latest/Guides/Using-an-Alternate-Config-Location/)
- [Windows Task Scheduler Best Practices](https://docs.microsoft.com/en-us/windows/win32/taskschd/task-scheduler-start-page)
- [Sysinternals PsExec Documentation](https://docs.microsoft.com/en-us/sysinternals/downloads/psexec)
- [Running PowerShell as SYSTEM](https://devblogs.microsoft.com/scripting/powertip-run-powershell-as-system-account/)
