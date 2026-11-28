param (
    [string]$json_input
)

$tempZipPath = $null
try {
    $inputData = $json_input | ConvertFrom-Json -ErrorAction Stop
    $analysisPath = $inputData.forensic_analysis_path
    $timestamp = $inputData.analysis_timestamp
    $hostname = $inputData.system_hostname
    $browserName = $inputData.selected_browser -replace '\s', '-'
    $expectedFiles = @($inputData.forensic_results)

    if ($timestamp -notmatch '^[a-zA-Z0-9_-]+$' -or
        $hostname -notmatch '^[a-zA-Z0-9_.-]+$' -or
        $browserName -notin @('Google-Chrome', 'Microsoft-Edge', 'Brave')) {
        throw 'Collection requires a valid timestamp, hostname, and browser.'
    }
    if (!$expectedFiles.Count -or $expectedFiles -contains $null -or $expectedFiles -contains '') {
        throw 'No forensic result files were supplied.'
    }

    $manifestPath = Join-Path $analysisPath "hindsight-$timestamp.json" -ErrorAction Stop
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $records = @($manifest.processes)
    if ($records.Count -ne $expectedFiles.Count -or
        (Compare-Object $expectedFiles @($records.output) -CaseSensitive)) {
        throw 'Process records do not match the expected result files.'
    }

    foreach ($record in $records) {
        $process = Get-Process -Id $record.id -ErrorAction SilentlyContinue
        if ($process -and !$process.HasExited) {
            try {
                $startTicks = $process.StartTime.ToUniversalTime().Ticks.ToString()
            } catch {
                if (!$process.HasExited) { throw }
                $startTicks = '0'
            }
            if ($startTicks -ne '0' -and $startTicks -eq $record.start_ticks) {
                throw "Hindsight is still processing: $($record.output)"
            }
        }
        $file = Get-Item -LiteralPath $record.output -ErrorAction Stop
        if ($file.PSIsContainer -or $file.Length -eq 0) {
            throw "Expected a non-empty result file: $($record.output)"
        }
    }

    $zipPath = Join-Path $analysisPath "$hostname-$browserName-$timestamp.zip" -ErrorAction Stop
    $tempZipPath = Join-Path $analysisPath "hindsight-$([guid]::NewGuid()).zip" -ErrorAction Stop
    Compress-Archive -LiteralPath $expectedFiles -DestinationPath $tempZipPath -ErrorAction Stop
    if (!(Test-Path -LiteralPath $tempZipPath -PathType Leaf)) {
        throw 'ZIP file is missing after compression.'
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $archive = [IO.Compression.ZipFile]::OpenRead($tempZipPath)
    try {
        if ($archive.Entries.Count -ne $expectedFiles.Count) {
            throw 'ZIP entry count does not match the expected result files.'
        }
        foreach ($path in $expectedFiles) {
            $file = Get-Item -LiteralPath $path -ErrorAction Stop
            $entry = $archive.GetEntry($file.Name)
            if (!$entry -or $entry.Length -ne $file.Length) {
                throw "ZIP entry is missing or has an unexpected size: $($file.Name)"
            }
        }
    } finally {
        $archive.Dispose()
    }
    Move-Item -LiteralPath $tempZipPath -Destination $zipPath -Force -ErrorAction Stop
    $result = @{
        has_processing_errors = $false
        zip_file_path = $zipPath
    }
} catch {
    $result = @{
        has_processing_errors = $true
        exception_messages = @($_.Exception.Message)
    }
} finally {
    if ($tempZipPath) {
        Remove-Item -LiteralPath $tempZipPath -Force -ErrorAction SilentlyContinue
    }
}

$result | ConvertTo-Json -Depth 2
