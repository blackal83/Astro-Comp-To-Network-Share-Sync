# Astrophoto Automated NAS Offloader (`Watch-ImageSequences`)

A lightweight, zero-dependency Windows PowerShell background watcher that monitors your local imaging directory, copies completed frames to a network share (NAS), verifies every transfer via **SHA-256 checksums**, safely removes local copies to free up observatory mini-PC storage, and quarantines filename collisions without ever overwriting data.

Designed for headless observatory computers (such as PrimaLuceLab EAGLE, MeLE Quieter, or Intel NUC rigs) running Windows 10/11.

---

## Key Features

* **Real-Time & Scheduled Sweeps:** Uses `System.IO.FileSystemWatcher` for near-instant offloading as your software saves frames, backed by a periodic full-directory sweep to catch any files written during brief network dropouts.
* **Write-Lock & Stability Verification:** Waits for file sizes to stabilize and confirms your software has released its exclusive file lock before touching any `.fits`, `.fit`, `.xisf`, `.tif`, or `.tiff` file (ignoring temporary/incomplete scratch files).
* **Cryptographic SHA-256 Verification:** Computes the SHA-256 hash of the local source file and the copied NAS file. Local files are **only** deleted if both hashes match byte-for-byte.
* **Smart Collision Handling:**
  * **Identical Hash:** If a file with the same relative path already exists on the NAS and has an identical SHA-256 hash, the redundant local copy is safely cleaned up.
  * **Different Hash (True Conflict):** If a file with the same name exists on the NAS with a *different* hash, nothing is overwritten. The local file is moved to a `sequences_conflicts` quarantine folder preserving its full relative directory path (`Target\Date\Type\...`) so you can inspect it later.
* **Clean Folder Pruning:** Automatically removes empty session subfolders bottom-up after frames are offloaded while keeping your root `Targets` and `Calibration_Library` folders intact.
* **Network-Outage Safe:** If your NAS is unreachable or offline, the script logs a warning and leaves all frames safely on the local SSD until the network recovers.

---

## Prerequisites

* **OS:** Windows 10 or Windows 11 (PowerShell 5.1+)
* **Imaging Software:** N.I.N.A. (or any capture software saving `.fits`, `.fit`, `.xisf`, or `.tiff` files into a structured folder hierarchy)
* **Network Storage:** A NAS or network share accessible via **UNC path** (e.g., `\\192.168.1.50\Astronomy` or `\\MyNAS\Astrophotography`)

### Storing NAS Credentials (If Password-Protected)
If your NAS share requires a username and password, save those credentials in **Windows Credential Manager** under the Windows account that runs your software:
1. Open **Control Panel** → **Credential Manager** → **Windows Credentials**.
2. Click **Add a Windows credential**.
3. Enter the NAS IP address or hostname (e.g., `192.168.1.50`), along with your NAS username and password.
4. Verify access in PowerShell without a password prompt:
   ```powershell
   Test-Path "\\192.168.1.50\Astronomy\"
   ```
   *(Should return `True`.)*

---

## Installation

### 1. Create the Script Directory
Create a folder on your observatory PC (for example, `C:\Scripts\NinaOffloader`) and place `Watch-NinaSequences.ps1` inside it.

### 2. Configure Your Paths
Open `Watch-NinaSequences.ps1` and update the four path variables at the top of the file to match your setup:

```powershell
$SourceRoot   = "C:\Users\<YourUsername>\Documents\N.I.N.A\sequences"
$DestRoot     = "\\192.168.1.50\Astronomy"
$ConflictRoot = "C:\Users\<YourUsername>\Documents\N.I.N.A\sequences_conflicts"
$LogDir       = "C:\Scripts\NinaOffloader\logs"
```

> **Tip:** Always use a **UNC path** (`\\Server\Share` or `\\IP\Share`) rather than a mapped drive letter (`V:\` or `Z:\`) for `$DestRoot`. Windows background tasks and scheduled jobs frequently fail to resolve user-mapped drive letters, whereas UNC paths work reliably across sessions.

### 3. Test Interactively First
Run the script manually in PowerShell once to verify permissions, hashing, and network throughput before automating it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\NinaOffloader\Watch-NinaSequences.ps1"
```

Check the daily log file in `C:\Scripts\NinaOffloader\logs\offload_YYYY-MM-DD.log` to confirm frames are transferring with `VERIFIED & MOVED` entries, then press `Ctrl + C` to stop the manual test.

### 4. Register as a Background Scheduled Task
To have the watcher start silently every time you log into your observatory PC, open PowerShell and run the following commands (replacing `<YourUsername>` with your Windows account name):

```powershell
$Action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Scripts\NinaOffloader\Watch-NinaSequences.ps1"
$Trigger  = New-ScheduledTaskTrigger -AtLogOn -User "<YourUsername>"
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 0) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName "NinaNasOffloader" -Action $Action -Trigger $Trigger -Settings $Settings -User "<YourUsername>" -RunLevel Limited -Force
Start-ScheduledTask -TaskName "NinaNasOffloader"
```

> **Why `-RunLevel Limited`?** Windows UAC isolates elevated (`Highest`) tasks into a separate logon session that cannot access saved Windows Credential Manager SMB entries. Running at `Limited` (standard user privilege) allows the background task to seamlessly reuse your saved NAS credentials while keeping the PowerShell window completely hidden.

---

## Monitoring & Management

### View Live Transfer Logs
Monitor real-time progress in PowerShell:
```powershell
Get-Content -Path "C:\Scripts\NinaOffloader\logs\offload_$(Get-Date -Format 'yyyy-MM-dd').log" -Wait -Tail 20
```

### Check Task Status
```powershell
Get-ScheduledTask -TaskName "NinaNasOffloader" | Select-Object TaskName, State
```

### Stop or Restart the Background Task
If you need to edit the script or pause offloading:
```powershell
# Stop the task and background process
Stop-ScheduledTask -TaskName "NinaNasOffloader"
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' AND CommandLine LIKE '%Watch-NinaSequences.ps1%'" | Invoke-CimMethod -MethodName Terminate

# Restart the task
Start-ScheduledTask -TaskName "NinaNasOffloader"
```

---

## How Folder Structure Is Preserved

Whatever subfolder hierarchy your software writes inside `$SourceRoot` is mirrored identically to `$DestRoot` (and `$ConflictRoot` if a hash mismatch occurs):

```text
Local N.I.N.A. Path:
  C:\...\N.I.N.A\sequences\Targets\NGC 1333\2026-11-16\LIGHT\...\frame_0001.fits

Mirrored NAS Path:
  \\192.168.1.50\Astronomy\Targets\NGC 1333\2026-11-16\LIGHT\...\frame_0001.fits

Quarantined Conflict Path (only if filename matches NAS but SHA-256 differs):
  C:\...\N.I.N.A\sequences_conflicts\Targets\NGC 1333\2026-11-16\LIGHT\...\frame_0001.fits
```

---

## License

MIT License — free to use, modify, and share with the astrophotography community.
