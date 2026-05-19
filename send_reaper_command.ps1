param(
  [Parameter(Mandatory=$true)]
  [string]$CommandPath,
  [string]$BridgeRoot = $PSScriptRoot,
  [switch]$Wait,
  [int]$TimeoutMs = 30000
)

$ErrorActionPreference = "Stop"

function New-CommandId {
  $stamp = Get-Date -Format "yyyy-MM-ddTHH-mm-ss"
  $suffix = -join ((48..57 + 97..102) | Get-Random -Count 4 | ForEach-Object {[char]$_})
  return "manual-$stamp-$suffix"
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
  param([string]$Path, [object]$Value)
  $tmp = "$Path.tmp"
  Write-Utf8NoBom -Path $tmp -Text ($Value | ConvertTo-Json -Depth 40)
  if (Test-Path -LiteralPath $Path) {
    Remove-Item -LiteralPath $Path -Force
  }
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

$command = Get-Content -LiteralPath $CommandPath -Raw | ConvertFrom-Json
if (-not $command.id -or [string]$command.id -eq "<auto>") {
  $command | Add-Member -NotePropertyName id -NotePropertyValue (New-CommandId) -Force
}
$command | Add-Member -NotePropertyName created_at -NotePropertyValue (Get-Date -Format "o") -Force
if (-not $command.created_by) {
  $command | Add-Member -NotePropertyName created_by -NotePropertyValue "manual" -Force
}

$id = [string]$command.id
$inboxPath = Join-Path $BridgeRoot "inbox\$id.json"
$outboxPath = Join-Path $BridgeRoot "outbox\$id.json"

Write-JsonAtomic -Path $inboxPath -Value $command
Write-Host "Sent command $id"

if (-not $Wait) {
  exit 0
}

$deadline = (Get-Date).AddMilliseconds($TimeoutMs)
while ((Get-Date) -lt $deadline) {
  if (Test-Path -LiteralPath $outboxPath) {
    Get-Content -LiteralPath $outboxPath -Raw
    exit 0
  }
  Start-Sleep -Milliseconds 250
}

Write-Error "Timed out waiting for $outboxPath"
