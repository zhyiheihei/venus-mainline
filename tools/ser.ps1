param([string]$file = "", [int]$sec = 8, [string]$port = "COM3", [int]$baud = 115200, [int]$waitsec = 0)
$sw0 = [Diagnostics.Stopwatch]::StartNew()
$p = $null
while ($true) {
  try {
    $p = New-Object System.IO.Ports.SerialPort $port,$baud,"None",8,"One"
    $p.ReadTimeout = 500
    $p.Open()
    break
  } catch {
    if ($p -ne $null) { $p.Dispose(); $p = $null }
    if ($sw0.Elapsed.TotalSeconds -ge $waitsec) { Write-Output "OPEN-FAIL: $($_.Exception.Message)"; exit 1 }
    Start-Sleep -Milliseconds 500
  }
}
$p.NewLine = "`n"
Start-Sleep -Milliseconds 300
$p.DiscardInBuffer()
if ($file -ne "" -and (Test-Path $file)) {
  Get-Content -Path $file -Encoding UTF8 | ForEach-Object { if ($_ -ne "") { $p.WriteLine($_) }; Start-Sleep -Milliseconds 120 }
  $p.WriteLine("")
}
$sw = [Diagnostics.Stopwatch]::StartNew()
$sb = New-Object System.Text.StringBuilder
while ($sw.Elapsed.TotalSeconds -lt $sec) {
  try { [void]$sb.Append($p.ReadExisting()) } catch { }
  Start-Sleep -Milliseconds 150
}
$p.Close()
Write-Output $sb.ToString()
