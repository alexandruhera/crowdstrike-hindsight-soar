param (
    [string]$json_input
)

$ErrorActionPreference = 'Stop'

function Get-CollectionResult($request) {
    $runId = $request.run_id
    if ($runId -isnot [string] -or $runId -notmatch '^[0-9a-fA-F]{32}$') {
        throw 'Missing or invalid run_id. Let runs from the previous workflow finish with their original collector.'
    }
    $directory = Get-Item -LiteralPath $request.forensic_analysis_path -Force
    if ($directory -isnot [IO.DirectoryInfo]) {
        throw 'The upstream analysis path must be a directory.'
    }
    for ($ancestor = $directory; $null -ne $ancestor; $ancestor = $ancestor.Parent) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'The analysis path contains a reparse point.'
        }
    }

    if ($request.forensic_results -isnot [array] -or $request.forensic_results.Count -eq 0) {
        throw 'Collection requires at least one expected result file.'
    }
    $files = @{}
    $pending = $false
    foreach ($path in $request.forensic_results) {
        if ($path -isnot [string] -or -not [IO.Path]::IsPathRooted($path)) {
            throw 'Expected result paths must be absolute.'
        }
        $fullPath = [IO.Path]::GetFullPath($path)
        $name = [IO.Path]::GetFileName($fullPath)
        $comparison = [StringComparison]::Ordinal
        if ([IO.Path]::DirectorySeparatorChar -eq '\') {
            $comparison = [StringComparison]::OrdinalIgnoreCase
        }
        if (-not [string]::Equals([IO.Path]::GetDirectoryName($fullPath), $directory.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar), $comparison) -or
            $name -notlike "*$runId*" -or $name -match '[:/\\]' -or
            [IO.Path]::GetExtension($name) -notin '.jsonl', '.sqlite', '.xlsx' -or $files.ContainsKey($name)) {
            throw "Invalid or duplicate result path for this execution: $path"
        }
        $files[$name] = $fullPath
        try {
            $marker = Get-Item -LiteralPath "$fullPath.status.json" -Force
        } catch [System.Management.Automation.ItemNotFoundException] {
            $pending = $true
            continue
        }
        if ($marker -isnot [IO.FileInfo] -or ($marker.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Invalid status file for $name."
        }
        $status = [IO.File]::ReadAllText($marker.FullName) | ConvertFrom-Json
        if ($status.run_id -ne $runId) {
            throw "The status file for $name belongs to another execution."
        }
        if ($status.status -eq 'failed') {
            throw "Hindsight failed for ${name}: $($status.message)"
        }
        if ($status.status -ne 'ready') {
            throw "Unrecognized status for $name."
        }
        $file = Get-Item -LiteralPath $fullPath -Force
        if ($file -isnot [IO.FileInfo] -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Invalid completed result for $name."
        }
    }
    if ($pending) {
        return @{
            collection_status = 'pending'
            has_processing_errors = $true
            exception_messages = @('Waiting for Hindsight to finish.')
        }
    }

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zipPath = Join-Path $directory.FullName "hindsight-$runId.zip"
    if (-not (Test-Path -LiteralPath $zipPath)) {
        # Each poll writes a private temporary ZIP. Only a fully closed archive is published.
        $tempPath = Join-Path $directory.FullName ("hindsight-{0}.tmp" -f [guid]::NewGuid().ToString('N'))
        try {
            $archive = [IO.Compression.ZipFile]::Open($tempPath, [IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($name in $files.Keys) {
                    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $files[$name], $name)
                }
            } finally {
                $archive.Dispose()
            }
            try {
                [IO.File]::Move($tempPath, $zipPath)
            } catch [IO.IOException] {
                if (-not [IO.File]::Exists($zipPath)) { throw }
                # Another poll published this run's archive. Verify the winner below.
            }
        } finally {
            [IO.File]::Delete($tempPath)
        }
    }

    $published = Get-Item -LiteralPath $zipPath -Force
    if ($published -isnot [IO.FileInfo] -or ($published.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The published archive must be a regular file.'
    }
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        if ($archive.Entries.Count -ne $files.Count) { throw 'The archive entry count differs from the expected results.' }
        foreach ($name in $files.Keys) {
            $entry = $archive.GetEntry($name)
            $source = [IO.FileInfo]::new($files[$name])
            if ($null -eq $entry -or $entry.Length -ne $source.Length) {
                throw "Archive verification failed for $name."
            }
            # A matching ZIP directory can still describe corrupt or substituted bytes.
            $stream = $entry.Open()
            try {
                $archivedHash = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash
            } finally {
                $stream.Dispose()
            }
            $sourceHash = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
            if ($sourceHash -ne $archivedHash) {
                throw "The archive contents differ from the completed result for $name."
            }
        }
    } finally {
        $archive.Dispose()
    }
    return @{ collection_status = 'ready'; has_processing_errors = $false; zip_file_path = $zipPath }
}

try {
    $request = $json_input | ConvertFrom-Json
    $result = Get-CollectionResult $request
} catch {
    $result = @{ collection_status = 'failed'; has_processing_errors = $true; exception_messages = @($_.Exception.Message) }
}
$result | ConvertTo-Json -Depth 3
