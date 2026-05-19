param(
  [string]$BridgeRoot = (Split-Path -Parent $PSScriptRoot),
  [switch]$Once
)

$ErrorActionPreference = "Stop"

$ConfigPath = Join-Path $BridgeRoot "bridge\bridge_config.json"
$JobsDir = Join-Path $BridgeRoot "jobs"
$DoneDir = Join-Path $BridgeRoot "jobs_done"
$LogPath = Join-Path $BridgeRoot "logs\worker.log"

function Write-Log {
  param([string]$Message)
  $stamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
  Add-Content -LiteralPath $LogPath -Value "[$stamp] $Message"
}

function Write-Utf8NoBom {
  param(
    [string]$Path,
    [string]$Text
  )
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Write-JsonAtomic {
  param(
    [string]$Path,
    [object]$Value
  )
  $tmp = "$Path.tmp"
  Write-Utf8NoBom -Path $tmp -Text ($Value | ConvertTo-Json -Depth 40)
  if (Test-Path -LiteralPath $Path) {
    Remove-Item -LiteralPath $Path -Force
  }
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Process-Job {
  param([string]$JobPath)

  $jobName = Split-Path -Leaf $JobPath
  if ($jobName.EndsWith(".tmp")) { return }

  $processingPath = Join-Path $JobsDir "$jobName.processing"
  Move-Item -LiteralPath $JobPath -Destination $processingPath -Force

  try {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $job = Get-Content -LiteralPath $processingPath -Raw | ConvertFrom-Json
    $id = if ($job.id) { [string]$job.id } else { [IO.Path]::GetFileNameWithoutExtension($jobName) }

    Write-Log "start $id"

    $outPath = if ($job.out) {
      [string]$job.out
    } else {
      Join-Path $DoneDir "drums_$id.mid"
    }

    $specPath = Join-Path $DoneDir "spec_$id.json"
    Write-Utf8NoBom -Path $specPath -Text ($job.spec | ConvertTo-Json -Depth 40)

    if ($job.dry_run -eq $true) {
      Write-JsonAtomic -Path (Join-Path $DoneDir "$id.result.json") -Value @{
        id = $id
        ok = $true
        dry_run = $true
        message = "Dry run: resolved drum spec, no MIDI written."
        spec_path = $specPath
        spec = $job.spec
      }
      Move-Item -LiteralPath $processingPath -Destination (Join-Path $DoneDir "$jobName.done") -Force
      Write-Log "dry-run ok $id"
      return
    }

    $python = [string]$config.python_exe
    $generator = [string]$config.drum_generator
    $bpm = if ($job.bpm) { [string]$job.bpm } else { "130" }
    $bars = if ($job.bars) { [string]$job.bars } else { "4" }

    $args = @(
      $generator,
      "--bpm", $bpm,
      "--bars", $bars,
      "--out", $outPath,
      "--spec", "@$specPath"
    )

    $stdoutPath = Join-Path $DoneDir "$id.stdout.txt"
    $stderrPath = Join-Path $DoneDir "$id.stderr.txt"
    $process = Start-Process -FilePath $python -ArgumentList $args -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

    if ($process.ExitCode -ne 0) {
      throw "generate_drums.py exited with code $($process.ExitCode). See $stderrPath"
    }

    if (-not (Test-Path -LiteralPath $outPath)) {
      throw "Expected MIDI was not created: $outPath"
    }

    Write-JsonAtomic -Path (Join-Path $DoneDir "$id.result.json") -Value @{
      id = $id
      ok = $true
      message = "Generated drum MIDI."
      midi_path = $outPath
      spec_path = $specPath
      bpm = [double]$bpm
      bars = [int]$bars
      stdout = $stdoutPath
      stderr = $stderrPath
    }

    Move-Item -LiteralPath $processingPath -Destination (Join-Path $DoneDir "$jobName.done") -Force
    Write-Log "ok $id"
  } catch {
    $id = [IO.Path]::GetFileNameWithoutExtension($jobName)
    Write-JsonAtomic -Path (Join-Path $DoneDir "$id.result.json") -Value @{
      id = $id
      ok = $false
      message = $_.Exception.Message
      error = @{
        code = "WORKER_JOB_FAILED"
        details = $_.Exception.ToString()
      }
    }
    Move-Item -LiteralPath $processingPath -Destination (Join-Path $DoneDir "$jobName.failed") -Force
    Write-Log "fail $id $($_.Exception.Message)"
  }
}

New-Item -ItemType Directory -Force -Path $JobsDir, $DoneDir, (Split-Path -Parent $LogPath) | Out-Null
Write-Log "worker started"

do {
  Get-ChildItem -LiteralPath $JobsDir -Filter "*.json" -File |
    Where-Object { -not $_.Name.EndsWith(".tmp") -and -not $_.Name.EndsWith(".processing") } |
    Sort-Object Name |
    ForEach-Object { Process-Job -JobPath $_.FullName }

  if ($Once) { break }
  Start-Sleep -Milliseconds 500
} while ($true)
