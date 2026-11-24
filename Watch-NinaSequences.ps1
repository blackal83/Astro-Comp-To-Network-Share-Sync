# Watch-NinaSequences.ps1
# Watches N.I.N.A. sequences folder, verifies SHA-256 copy to V:\, deletes local on match,
# and quarantines filename collisions to sequences_conflicts.

$SourceRoot   = "C:\Users\PrimaLuceLab\Documents\N.I.N.A\sequences"
$DestRoot     = "\\192.168.4.75\Astrophotography"
$ConflictRoot = "C:\Users\PrimaLuceLab\Documents\N.I.N.A\sequences_conflicts"
$LogDir       = "C:\Scripts\NinaOffloader\logs"

# Extensions N.I.N.A. outputs (ignores .tmp or incomplete scratch files)
$AllowedExtensions = @(".fits", ".fit", ".xisf", ".tif", ".tiff")

foreach ($dir in @($SourceRoot, $ConflictRoot, $LogDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logFile = Join-Path $LogDir ("offload_{0}.log" -f (Get-Date -Format "yyyy-MM-dd"))
    Add-Content -LiteralPath $logFile -Value "[$timestamp] [$Level] $Message"
}

function Test-FileReady {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

    try {
        $size1 = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        if ($size1 -eq 0) { return $false }
        Start-Sleep -Seconds 2
        $size2 = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        if ($size1 -ne $size2) { return $false }

        # Verify N.I.N.A. has released its exclusive write lock
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $stream.Close()
        return $true
    }
    catch {
        return $false
    }
}

function Remove-EmptyParents {
    param([string]$FilePath)

    $protectedRoots = @(
        $SourceRoot.TrimEnd('\').ToLowerInvariant(),
        (Join-Path $SourceRoot "Targets").TrimEnd('\').ToLowerInvariant(),
        (Join-Path $SourceRoot "Calibration_Library").TrimEnd('\').ToLowerInvariant()
    )

    $parent = Split-Path -Parent $FilePath
    while ($parent -and ($protectedRoots -notcontains $parent.TrimEnd('\').ToLowerInvariant())) {
        if (-not (Test-Path -LiteralPath $parent)) { break }

        Start-Sleep -Milliseconds 150

        $items = @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -notin @("desktop.ini", "Thumbs.db")
        })

        if ($items.Count -eq 0) {
            try {
                Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction Stop
                $parent = Split-Path -Parent $parent
            }
            catch {
                Write-Log "Could not remove empty folder '$parent' (likely open in Explorer): $($_.Exception.Message)" "WARN"
                break
            }
        }
        else {
            break
        }
    }
}


function Process-AstroFile {
    param([string]$FullPath)

    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { return }

    $ext = [System.IO.Path]::GetExtension($FullPath).ToLowerInvariant()
    if ($AllowedExtensions -notcontains $ext) { return }

    # Wait until N.I.N.A. finishes writing the frame
    $attempts = 0
    while (-not (Test-FileReady -Path $FullPath)) {
        $attempts++
        if ($attempts -ge 15) {
            Write-Log "File still locked or growing after 30s, deferring to sweep: $FullPath" "WARN"
            return
        }
    }

    # Ensure V:\ is reachable before doing anything
    if (-not (Test-Path -LiteralPath "$DestRoot\")) {
        Write-Log "Destination $DestRoot is offline/unreachable. Leaving file locally: $FullPath" "WARN"
        return
    }

    $relativePath = $FullPath.Substring($SourceRoot.Length).TrimStart('\')
    $destPath     = Join-Path $DestRoot $relativePath
    $conflictPath = Join-Path $ConflictRoot $relativePath

    # CAVEAT: Collision check on NAS
    # CAVEAT: Collision check on NAS (auto-delete if identical SHA-256; quarantine if different)
    if (Test-Path -LiteralPath $destPath) {
        try {
            $localHash = (Get-FileHash -LiteralPath $FullPath -Algorithm SHA256 -ErrorAction Stop).Hash
            $nasHash   = (Get-FileHash -LiteralPath $destPath -Algorithm SHA256 -ErrorAction Stop).Hash

            if ($localHash -eq $nasHash) {
                Remove-Item -LiteralPath $FullPath -Force -ErrorAction Stop
                Remove-EmptyParents -FilePath $FullPath
                Write-Log "DUPLICATE CLEANED: '$relativePath' already exists on $DestRoot with identical SHA256 ($($localHash.Substring(0,12))...). Deleted local copy." "INFO"
            }
            else {
                $conflictDir = Split-Path -Parent $conflictPath
                if (-not (Test-Path -LiteralPath $conflictDir)) {
                    New-Item -ItemType Directory -Path $conflictDir -Force | Out-Null
                }

                # If a different conflict already exists in conflicts, append timestamp so nothing gets clobbered
                if (Test-Path -LiteralPath $conflictPath) {
                    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($conflictPath)
                    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
                    $conflictPath = Join-Path $conflictDir "${baseName}_${stamp}${ext}"
                }

                Move-Item -LiteralPath $FullPath -Destination $conflictPath -Force -ErrorAction Stop
                Remove-EmptyParents -FilePath $FullPath
                Write-Log "COLLISION [DIFFERENT HASHES: Local=$($localHash.Substring(0,12))... vs NAS=$($nasHash.Substring(0,12))...]: '$relativePath' moved to '$conflictPath'." "WARN"
            }
        }
        catch {
            Write-Log "Failed resolving collision for '$FullPath': $($_.Exception.Message)" "ERROR"
        }
        return
    }

    # Copy + SHA-256 Verification + Local Cleanup
    try {
        $localHash = (Get-FileHash -LiteralPath $FullPath -Algorithm SHA256 -ErrorAction Stop).Hash

        $destDir = Split-Path -Parent $destPath
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        Copy-Item -LiteralPath $FullPath -Destination $destPath -ErrorAction Stop
        $nasHash = (Get-FileHash -LiteralPath $destPath -Algorithm SHA256 -ErrorAction Stop).Hash

        if ($localHash -eq $nasHash) {
            Remove-Item -LiteralPath $FullPath -Force -ErrorAction Stop
            Remove-EmptyParents -FilePath $FullPath
            Write-Log "VERIFIED & MOVED: $relativePath (SHA256: $($localHash.Substring(0,12))...)" "INFO"
        }
        else {
            # Remove bad copy on NAS so future retries don't treat it as a valid collision
            Remove-Item -LiteralPath $destPath -Force -ErrorAction SilentlyContinue
            Write-Log "CHECKSUM MISMATCH on '$relativePath'! Local=$localHash NAS=$nasHash. Kept local file." "ERROR"
        }
    }
    catch {
        Write-Log "Transfer failed for '$relativePath': $($_.Exception.Message)" "ERROR"
    }
}

function Invoke-FullSweep {
    Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        Process-AstroFile -FullPath $_.FullName
    }

    # Bottom-up cleanup of any leftover empty folders under Targets and Calibration_Library
    $protectedRoots = @(
        $SourceRoot.TrimEnd('\').ToLowerInvariant(),
        (Join-Path $SourceRoot "Targets").TrimEnd('\').ToLowerInvariant(),
        (Join-Path $SourceRoot "Calibration_Library").TrimEnd('\').ToLowerInvariant()
    )

    Get-ChildItem -LiteralPath $SourceRoot -Recurse -Directory -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object {
            if ($protectedRoots -notcontains $_.FullName.TrimEnd('\').ToLowerInvariant()) {
                $items = @(Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue | Where-Object {
                    $_.Name -notin @("desktop.ini", "Thumbs.db")
                })
                if ($items.Count -eq 0) {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
}

Write-Log "=== NinaOffloader started. Watching $SourceRoot -> $DestRoot ==="

# 1. Initial sweep on startup for any leftover frames
Invoke-FullSweep

# 2. Real-time FileSystemWatcher
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $SourceRoot
$watcher.IncludeSubdirectories = $true
$watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::LastWrite
$watcher.InternalBufferSize = 65536
$watcher.EnableRaisingEvents = $true

# 3. Event loop + 5-minute safety sweep (catches missed events or network blips)
$lastSweep = Get-Date
try {
    while ($true) {
        $result = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::Created -bor [System.IO.WatcherChangeTypes]::Renamed, 5000)
        if (-not $result.TimedOut) {
            $changedPath = Join-Path $SourceRoot $result.Name
            Process-AstroFile -FullPath $changedPath
        }

        if (((Get-Date) - $lastSweep).TotalMinutes -ge 5) {
            Invoke-FullSweep
            $lastSweep = Get-Date
        }
    }
}
finally {
    $watcher.Dispose()
    Write-Log "=== NinaOffloader stopped ==="
}
