# PowerShell Profile with automatic transcription and context function

# Setup transcript directory
$TranscriptDir = if ($IsWindows -or $env:OS -eq "Windows_NT") {
    Join-Path $env:TEMP "PowerShell_Transcripts"
} else {
    Join-Path ($env:TMPDIR -or "/tmp") "powershell_transcripts"
}

if (-not (Test-Path $TranscriptDir)) {
    New-Item -ItemType Directory -Path $TranscriptDir -Force | Out-Null
}

# Generate transcript filename
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$Machine = $env:COMPUTERNAME -or (hostname)
$User = $env:USERNAME -or $env:USER
$TranscriptFile = "PowerShell_${Machine}_${User}_${Timestamp}_${PID}_original.txt"
$Global:TRANSCRIPT_PATH = Join-Path $TranscriptDir $TranscriptFile

# Set up sanitized transcript path
$SanitizedFile = "PowerShell_${Machine}_${User}_${Timestamp}_${PID}.txt"
$Global:SANITIZED_TRANSCRIPT_PATH = Join-Path $TranscriptDir $SanitizedFile

# Function to start the Python transcript sanitizer
function Start-TranscriptSanitizer {
    param(
        [string]$TranscriptPath,
        [string]$SanitizedPath
    )
    
    # Get the sanitizer script path based on platform
    $SanitizerRoot = if ($IsWindows -or $env:OS -eq "Windows_NT") {
        "C:\Tools"
    } else {
        "/opt"
    }
    
    $SanitizerDir = Join-Path $SanitizerRoot "presidio-secrets-sanitizer"
    $PythonScript = Join-Path $SanitizerDir "sanitizer.py"
    
    # Check if Python script exists
    if (-not (Test-Path $PythonScript)) {
        Write-Warning "Python sanitizer script not found at: $PythonScript"
        return $null
    }
    
    # Find Python executable (try common names)
    $PythonCmd = $null
    $PythonCommands = @("python", "python3", "py")
    
    foreach ($cmd in $PythonCommands) {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) {
            $PythonCmd = $cmd
            break
        }
    }
    
    if (-not $PythonCmd) {
        Write-Warning "Python executable not found. Please install Python."
        return $null
    }
    
    try {
        # Start the Python sanitizer as a background job (cross-platform)
        $Job = Start-Job -ScriptBlock {
            param($PythonCmd, $PythonScript, $TranscriptPath, $SanitizedPath)
            & $PythonCmd $PythonScript --watchdog $TranscriptPath -o $SanitizedPath
        } -ArgumentList $PythonCmd, $PythonScript, $TranscriptPath, $SanitizedPath
        $Global:SANITIZER_JOB = $Job
        return $Job
    } catch {
        Write-Warning "Failed to start transcript sanitizer: $($_.Exception.Message)"
        return $null
    }
}

# Start transcription - always use our own transcript file for logging
try {
    Start-Transcript -Path $Global:TRANSCRIPT_PATH -Append -IncludeInvocationHeader -Force
    # If PS_TRANSCRIPT_PATH wasn't set, set it to our transcript path for backwards compatibility
    if (-not $env:PS_TRANSCRIPT_PATH) {
        $env:PS_TRANSCRIPT_PATH = $Global:TRANSCRIPT_PATH
    }
    
    # Start the Python sanitizer in the background
    $SanitizerResult = Start-TranscriptSanitizer -TranscriptPath $Global:TRANSCRIPT_PATH -SanitizedPath $Global:SANITIZED_TRANSCRIPT_PATH
    if ($SanitizerResult) {
        Write-Host "Transcript sanitizer started successfully." -ForegroundColor Green
        Write-Host "Job State: $($SanitizerResult.State)" -ForegroundColor Yellow
    } else {
        Write-Host "Failed to start transcript sanitizer." -ForegroundColor Red
    }
} catch {
    Write-Warning "Could not start transcription: $($_.Exception.Message)"
}

function Get-Context {
    param(
        [Parameter(Position = 0)]
        [string]$Count = "1",
        [Alias("e")]
        [switch]$Environment,
        [switch]$original
    )
    
    if ($Environment) {
        if (-not $env:PS_TRANSCRIPT_PATH) {
            Write-Error "No transcript path available."
            return
        }
        
        Write-Host "`nEnvironment Variable Setup:" -ForegroundColor Cyan
        Write-Host "PowerShell: `$env:PS_TRANSCRIPT_PATH=`"$env:PS_TRANSCRIPT_PATH`"" -ForegroundColor White

        return
    }
    
    # Determine which transcript to use based on -original parameter
    if ($original) {
        # Use original transcript
        $TranscriptPath = if ($env:PS_TRANSCRIPT_PATH -and (Test-Path $env:PS_TRANSCRIPT_PATH)) {
            $env:PS_TRANSCRIPT_PATH
        } elseif ($Global:TRANSCRIPT_PATH -and (Test-Path $Global:TRANSCRIPT_PATH)) {
            $Global:TRANSCRIPT_PATH
        } else {
            $null
        }
    } else {
        # Use sanitized transcript (default)
        $TranscriptPath = if ($Global:SANITIZED_TRANSCRIPT_PATH -and (Test-Path $Global:SANITIZED_TRANSCRIPT_PATH)) {
            $Global:SANITIZED_TRANSCRIPT_PATH
        } elseif ($env:PS_TRANSCRIPT_PATH -and (Test-Path $env:PS_TRANSCRIPT_PATH)) {
            $env:PS_TRANSCRIPT_PATH
        } elseif ($Global:TRANSCRIPT_PATH -and (Test-Path $Global:TRANSCRIPT_PATH)) {
            $Global:TRANSCRIPT_PATH
        } else {
            $null
        }
    }
    
    if (-not $TranscriptPath) {
        $TranscriptType = if ($original) { "original" } else { "sanitized" }
        Write-Error "No $TranscriptType transcript file found. Ensure transcription is active."
        return
    }
    
    try {
        $Content = Get-Content $TranscriptPath -Raw
        $CommandBlocks = Extract-CommandsFromTranscript $Content
        
        if ($CommandBlocks.Count -eq 0) {
            Write-Host "No commands found." -ForegroundColor Yellow
            return
        }
        
        $BlocksToShow = if ($Count -eq "all") {
            $CommandBlocks
        } elseif ($Count -match '^\d+$') {
            $NumCount = [int]$Count
            $CommandBlocks | Select-Object -Last $NumCount
        } else {
            Write-Error "Invalid parameter. Use a number or 'all'."
            return
        }
        
        # Just output the raw command blocks
        foreach ($Block in $BlocksToShow) {
            Write-Host "`n$Block"
        }
        
    } catch {
        Write-Error "Error reading transcript: $($_.Exception.Message)"
    }
}

Set-Alias context Get-Context

function Extract-CommandsFromTranscript {
    param([string]$Content)
    
    $CommandBlocks = @()
    
    # Use regex to find all command blocks: Command start time, followed by asterisks, then content until next asterisks
    $Pattern = 'Command start time: \d+\s*\*{20,22}\s*([\s\S]*?)(?=\*{20,22}|$)'
    $Matches = [regex]::Matches($Content, $Pattern)
    
    foreach ($Match in $Matches) {
        $Block = $Match.Groups[1].Value.Trim()
        if ($Block) {
            # Filter out context commands and termination errors
            if ($Block -notmatch 'PS.*>\s*context' -and $Block -notmatch 'TerminatingError') {
                $CommandBlocks += $Block
            }
        }
    }
    
    return $CommandBlocks
}


function Show-TranscriptInfo {
    $CurrentPath = if ($env:PS_TRANSCRIPT_PATH -and (Test-Path $env:PS_TRANSCRIPT_PATH)) {
        $env:PS_TRANSCRIPT_PATH
    } elseif ($Global:TRANSCRIPT_PATH -and (Test-Path $Global:TRANSCRIPT_PATH)) {
        $Global:TRANSCRIPT_PATH
    } else {
        "No active transcript found"
    }
    
    $SanitizedPath = if ($Global:SANITIZED_TRANSCRIPT_PATH -and (Test-Path $Global:SANITIZED_TRANSCRIPT_PATH)) {
        $Global:SANITIZED_TRANSCRIPT_PATH
    } else {
        "No sanitized transcript found"
    }
    
    Write-Host "`nTranscript Information:" -ForegroundColor Cyan
    Write-Host "Current transcript file: $CurrentPath" -ForegroundColor White
    Write-Host "Sanitized transcript file: $SanitizedPath" -ForegroundColor White
    Write-Host "Environment variable: `$env:PS_TRANSCRIPT_PATH" -ForegroundColor White
    Write-Host "Storage location: Temporary directory (deleted after reboot)" -ForegroundColor Yellow
    
    # Show sanitizer status
    $SanitizerStatus = "Stopped"
    if ($Global:SANITIZER_JOB -and $Global:SANITIZER_JOB.State -eq "Running") {
        $SanitizerStatus = "Running (Job ID: $($Global:SANITIZER_JOB.Id))"
    }
    Write-Host "Sanitizer status: $SanitizerStatus" -ForegroundColor White
    
    Write-Host "`nAvailable commands:" -ForegroundColor Cyan
    Write-Host "  context           - Show last command with output (sanitized)" -ForegroundColor White
    Write-Host "  context 5         - Show last 5 commands with outputs (sanitized)" -ForegroundColor White
    Write-Host "  context all       - Show all commands with outputs (sanitized)" -ForegroundColor White
    Write-Host "  context -original - Show last command from original transcript" -ForegroundColor White
    Write-Host "  context 5 -original - Show last 5 commands from original transcript" -ForegroundColor White
    Write-Host "  context -e        - Get environment variable setup commands" -ForegroundColor White
    Write-Host "  Show-TranscriptInfo - Show this information" -ForegroundColor White
    Write-Host "  Stop-TranscriptSanitizer - Stop the background sanitizer process" -ForegroundColor White
}

# Function to stop the transcript sanitizer
function Stop-TranscriptSanitizer {
    try {
        # Stop the job (cross-platform)
        if ($Global:SANITIZER_JOB) {
            Stop-Job -Job $Global:SANITIZER_JOB -PassThru | Remove-Job
            $Global:SANITIZER_JOB = $null
        }
    } catch {
        # Silently handle cleanup errors
    }
}

# Cleanup on exit
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    try { Stop-Transcript } catch { }
    try { Stop-TranscriptSanitizer } catch { }
}

# Welcome message
Write-Host "PowerShell context tracking active. Use 'context' command or 'Show-TranscriptInfo' for help." -ForegroundColor Green
