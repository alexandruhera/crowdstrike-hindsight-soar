param (
    [string]$json_input
)

$ErrorActionPreference = 'Stop'

# This standalone worker is written into the prepared case directory so it can
# outlive the RTR action. Its input is data in the child process environment.
$worker = {
    $ErrorActionPreference = 'Stop'
    $job = $env:HINDSIGHT_PROFILE_JOB | ConvertFrom-Json
    $result = "$($job.output_base).$($job.format)"
    $marker = @{ run_id = $job.run_id; status = 'failed' }
    try {
        $cliArgs = @('-i', $job.profile, '-o', $job.output_base, '-f', $job.format, '-t', 'UTC')
        # Windows PowerShell can turn redirected native stderr into error records.
        # Hindsight's exit code determines whether it finished successfully.
        $ErrorActionPreference = 'Continue'
        & $job.tool @cliArgs *> $null
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($exitCode -ne 0) { throw "Hindsight exited with code $exitCode." }
        if (-not [IO.File]::Exists($result)) { throw 'Hindsight did not create its expected output file.' }

        switch ($job.format) {
            'jsonl' {
                $reader = [IO.File]::OpenText($result)
                try {
                    # Zero lines is valid when a profile contains no artifact records.
                    while ($null -ne ($line = $reader.ReadLine())) {
                        if (-not $line.TrimStart().StartsWith('{')) { throw 'Invalid JSONL record.' }
                        $null = ConvertFrom-Json -InputObject $line -ErrorAction Stop
                    }
                } finally { $reader.Dispose() }
            }
            'sqlite' {
                $stream = [IO.File]::OpenRead($result)
                try {
                    $header = New-Object byte[] 16
                    $bytes = $stream.Read($header, 0, $header.Length)
                    if ($bytes -ne 16 -or $stream.Length -lt 100 -or
                        [Text.Encoding]::ASCII.GetString($header) -cne "SQLite format 3`0") {
                        throw 'Invalid SQLite header.'
                    }
                } finally { $stream.Dispose() }
            }
            'xlsx' {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $archive = [IO.Compression.ZipFile]::OpenRead($result)
                try {
                    if (-not $archive.GetEntry('[Content_Types].xml') -or -not $archive.GetEntry('xl/workbook.xml')) {
                        throw 'Invalid XLSX workbook.'
                    }
                } finally { $archive.Dispose() }
            }
        }
        $marker.status = 'ready'
    } catch {
        $marker.message = $_.Exception.Message
    }

    $statusPath = "$result.status.json"
    $tempPath = "$statusPath.$PID.tmp"
    [IO.File]::WriteAllText($tempPath, ($marker | ConvertTo-Json -Compress))
    [IO.File]::Move($tempPath, $statusPath)
}

try {
    $inputData = ConvertFrom-Json -InputObject $json_input
    $paths = @{
        'Google Chrome'  = 'AppData/Local/Google/Chrome/User Data'
        'Microsoft Edge' = 'AppData/Local/Microsoft/Edge/User Data'
        'Brave'          = 'AppData/Local/BraveSoftware/Brave-Browser/User Data'
    }
    $browser = $inputData.selected_browser
    $format = $inputData.output_format
    $hostname = $inputData.system_hostname
    if (-not $paths.ContainsKey($browser)) { throw 'Unsupported browser.' }
    if ($format -cnotin @('jsonl', 'sqlite', 'xlsx')) { throw 'Unsupported output format.' }
    if ($hostname -notmatch '^[a-zA-Z0-9_.-]+$') { throw 'Invalid system hostname.' }

    $now = (Get-Date).ToUniversalTime()
    $cutoff = $null
    if ($inputData.PSObject.Properties['profile_history_days']) {
        $days = $inputData.profile_history_days
        if (($days -isnot [int] -and $days -isnot [long]) -or $days -lt 1) {
            throw 'profile_history_days must be a positive integer.'
        }
        $cutoff = $now.AddDays(-$days)
    }

    # RTR executes separately from the interactive user's session.
    $interactive = (Get-CimInstance Win32_ComputerSystem).UserName
    if ($interactive -notmatch '^([^\\]+)\\([^\\]+)$') { throw 'Could not identify a domain-qualified interactive Windows user.' }
    $domain = $Matches[1]
    $name = $Matches[2]
    # Both values originate from Windows. Escape quotes for a WQL string literal.
    $domainFilter = $domain.Replace("'", "\'")
    $nameFilter = $name.Replace("'", "\'")
    $accounts = @(Get-CimInstance Win32_UserAccount -Filter "Domain = '$domainFilter' AND Name = '$nameFilter'" |
        Where-Object { $_.Domain -eq $domain -and $_.Name -eq $name })
    if ($accounts.Count -ne 1 -or $accounts[0].SID -notmatch '^S-1-\d+(?:-\d+)+$') {
        throw "Could not resolve a unique Windows SID for $interactive."
    }
    $sid = $accounts[0].SID
    $userProfiles = @(Get-CimInstance Win32_UserProfile -Filter "SID = '$sid'" |
        Where-Object { $_.SID -eq $sid -and $_.LocalPath })
    if ($userProfiles.Count -ne 1) { throw "Could not resolve a unique local profile for $interactive ($sid)." }
    $browserRoot = Join-Path $userProfiles[0].LocalPath $paths[$browser]
    $profiles = @(foreach ($entry in (Get-ChildItem -LiteralPath $browserRoot -Directory)) {
        if ($entry.Name -notmatch '^(Default|Profile\s\d+)$') { continue }
        if ($null -ne $cutoff) {
            $historyPath = Join-Path $entry.FullName 'History'
            try {
                $history = Get-Item -LiteralPath $historyPath -Force -ErrorAction Stop
            } catch [System.Management.Automation.ItemNotFoundException] {
                continue
            }
            if ($history.PSIsContainer -or $history.LastWriteTimeUtc -lt $cutoff) { continue }
        }
        $entry
    })

    $runId = [guid]::NewGuid().ToString('N')
    $timestamp = $now.ToString('yyyy-MM-ddTHH-mm')
    $response = [ordered]@{
        processing_status     = 'no_match'
        has_processing_errors = $false
        run_id                = $runId
        analysis_timestamp    = $timestamp
        user_data_path        = $browserRoot
        browser_profile_names = @($profiles | ForEach-Object { $_.Name })
        browser_profile_paths = @($profiles | ForEach-Object { $_.FullName })
        forensic_results      = @()
    }

    if ($profiles.Count -gt 0) {
        $directory = Get-Item -LiteralPath $inputData.forensic_analysis_path
        $tool = Get-Item -LiteralPath $inputData.forensic_tool_path
        if (-not $directory.PSIsContainer -or $tool.PSIsContainer -or $tool.Name -ine 'hindsight.exe' -or
            $tool.Directory.FullName -ine $directory.FullName -or ($tool.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Expected the deployed hindsight.exe in the prepared working directory.'
        }
        if ([Environment]::OSVersion.Platform -eq 'Win32NT' -and (Get-ExecutionPolicy) -in @('AllSigned', 'Restricted')) {
            throw 'Endpoint execution policy prevents starting the locally generated Hindsight worker.'
        }
        $workerPath = Join-Path $directory.FullName "hindsight-worker-$runId.ps1"
        [IO.File]::WriteAllText($workerPath, $worker.ToString())
        $shell = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' }
            elseif ([Environment]::OSVersion.Platform -eq 'Win32NT') { 'pwsh.exe' }
            else { 'pwsh' }
        foreach ($profile in $profiles) {
            $profileName = $profile.Name -replace '\s', '-'
            $browserName = $browser -replace '\s', '-'
            $outputBase = Join-Path $directory.FullName "$hostname-$browserName-$profileName-$timestamp-$runId"
            $job = @{ tool = $tool.FullName; profile = $profile.FullName; output_base = $outputBase; format = $format; run_id = $runId }
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = Join-Path $PSHOME $shell
            $start.Arguments = '-NoLogo -NoProfile -NonInteractive -File "' + $workerPath + '"'
            $start.WorkingDirectory = $directory.FullName
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.EnvironmentVariables['HINDSIGHT_PROFILE_JOB'] = ($job | ConvertTo-Json -Compress)
            # Give the detached child its own pipes so it cannot hold RTR stdout open.
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            try {
                $child = [Diagnostics.Process]::Start($start)
                $child.Dispose()
            } catch {
                throw "Could not start the Hindsight worker for $($profile.Name) (run $runId): $($_.Exception.Message)"
            }
            $response.forensic_results += "$outputBase.$format"
        }
        $response.processing_status = 'started'
    }
} catch {
    $response = [ordered]@{
        processing_status     = 'failed'
        has_processing_errors = $true
        exception_messages    = @($_.Exception.Message)
    }
}

$response | ConvertTo-Json -Depth 3 -Compress
