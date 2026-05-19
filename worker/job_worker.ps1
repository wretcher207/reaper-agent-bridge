param(
  [string]$BridgeRoot = (Split-Path -Parent $PSScriptRoot),
  [switch]$Once
)

# Generic job runner for the REAPER Agent Bridge.
#
# Agents that cannot run a shell drop a job JSON into <bridge_root>\jobs. Each
# job names a "tool" registered in bridge_config.json. This worker substitutes
# the job's params into the tool's argument template, runs the external program,
# and writes a result JSON to <bridge_root>\jobs_done.
#
# It knows nothing about drums, MIDI, or any specific program — every external
# tool is declared in config. To add a capability, register a tool; no code here
# changes.

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
  param([string]$Path, [string]$Text)
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Write-JsonAtomic {
  param([string]$Path, [object]$Value)
  $tmp = "$Path.tmp"
  Write-Utf8NoBom -Path $tmp -Text ($Value | ConvertTo-Json -Depth 40)
  if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Expand-Tokens {
  param([string]$Text, [hashtable]$Tokens)
  foreach ($key in $Tokens.Keys) {
    $Text = $Text.Replace("{$key}", [string]$Tokens[$key])
  }
  return $Text
}

function Process-Job {
  param([string]$JobPath)

  $jobName = Split-Path -Leaf $JobPath
  if ($jobName.EndsWith(".tmp")) { return }

  $processingPath = Join-Path $JobsDir "$jobName.processing"
  Move-Item -LiteralPath $JobPath -Destination $processingPath -Force
  $id = [IO.Path]::GetFileNameWithoutExtension($jobName)

  try {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $job = Get-Content -LiteralPath $processingPath -Raw | ConvertFrom-Json
    if ($job.id) { $id = [string]$job.id }

    Write-Log "start $id"

    if (-not $job.tool) {
      throw "Job is missing 'tool'. Name a tool registered in bridge_config.json."
    }
    $available = @()
    if ($config.tools) { $available = @($config.tools.PSObject.Properties.Name) }
    $tool = if ($config.tools) { $config.tools.$($job.tool) } else { $null }
    if (-not $tool) {
      throw "Unknown tool '$($job.tool)'. Registered tools: $($available -join ', ')"
    }

    # Tokens available to the tool's arg template.
    $tokens = @{
      id          = $id
      bridge_root = $BridgeRoot
      jobs        = $JobsDir
      jobs_done   = $DoneDir
    }
    if ($job.params) {
      foreach ($p in $job.params.PSObject.Properties) {
        $tokens[$p.Name] = $p.Value
      }
    }

    # If the tool consumes a JSON spec, write the job's spec object to a file
    # and expose {spec_file}.
    if ($tool.writes_spec -eq $true -and $job.spec) {
      $specPath = Join-Path $DoneDir "spec_$id.json"
      Write-Utf8NoBom -Path $specPath -Text ($job.spec | ConvertTo-Json -Depth 40)
      $tokens["spec_file"] = $specPath
    }

    # Resolve the output path: explicit job.out, else the tool's default_out.
    $outPath = $null
    if ($job.out) {
      $outPath = Expand-Tokens -Text ([string]$job.out) -Tokens $tokens
    } elseif ($tool.default_out) {
      $outPath = Expand-Tokens -Text ([string]$tool.default_out) -Tokens $tokens
    }
    if ($outPath) { $tokens["out"] = $outPath }

    $exe = Expand-Tokens -Text ([string]$tool.exe) -Tokens $tokens
    $argList = @()
    foreach ($a in @($tool.args)) {
      $argList += (Expand-Tokens -Text ([string]$a) -Tokens $tokens)
    }

    if ($job.dry_run -eq $true) {
      Write-JsonAtomic -Path (Join-Path $DoneDir "$id.result.json") -Value @{
        id        = $id
        ok        = $true
        dry_run   = $true
        tool      = [string]$job.tool
        message   = "Dry run: resolved command, nothing executed."
        resolved  = @{ exe = $exe; args = $argList; out = $outPath }
      }
      Move-Item -LiteralPath $processingPath -Destination (Join-Path $DoneDir "$jobName.done") -Force
      Write-Log "dry-run ok $id"
      return
    }

    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
      throw "Tool '$($job.tool)' exe not found: $exe"
    }

    $stdoutPath = Join-Path $DoneDir "$id.stdout.txt"
    $stderrPath = Join-Path $DoneDir "$id.stderr.txt"
    $process = Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -Wait -PassThru `
      -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

    if ($process.ExitCode -ne 0) {
      throw "Tool '$($job.tool)' exited with code $($process.ExitCode). See $stderrPath"
    }
    if ($outPath -and -not (Test-Path -LiteralPath $outPath)) {
      throw "Tool '$($job.tool)' did not produce expected output: $outPath"
    }

    $result = @{
      id          = $id
      ok          = $true
      tool        = [string]$job.tool
      message     = "Tool '$($job.tool)' completed."
      output_path = $outPath
      stdout      = $stdoutPath
      stderr      = $stderrPath
    }
    if ($tool.output_key) { $result[[string]$tool.output_key] = $outPath }

    Write-JsonAtomic -Path (Join-Path $DoneDir "$id.result.json") -Value $result
    Move-Item -LiteralPath $processingPath -Destination (Join-Path $DoneDir "$jobName.done") -Force
    Write-Log "ok $id"
  } catch {
    Write-JsonAtomic -Path (Join-Path $DoneDir "$id.result.json") -Value @{
      id      = $id
      ok      = $false
      message = $_.Exception.Message
      error   = @{ code = "WORKER_JOB_FAILED"; details = $_.Exception.ToString() }
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
