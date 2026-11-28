param (
    [string]$json_input
)

$ErrorActionPreference = 'Stop'
try {
    $request = $json_input | ConvertFrom-Json
    $path = $request.forensic_analysis_path
    if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathRooted($path)) {
        throw 'Fusion must supply an absolute analysis directory.'
    }
    if ([IO.Path]::DirectorySeparatorChar -eq '\' -and $path -notmatch '^[a-zA-Z]:[\\/]') {
        throw 'Fusion must supply an absolute local drive path.'
    }
    $directory = [IO.DirectoryInfo]::new($path)
    if ($null -eq $directory.Parent) { throw 'The analysis directory cannot be a filesystem root.' }
    for ($ancestor = $directory; $null -ne $ancestor; $ancestor = $ancestor.Parent) {
        if ($ancestor.Exists -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'The analysis path contains a reparse point.'
        }
    }
    $directory = [IO.Directory]::CreateDirectory($directory.FullName)
    if ($null -ne (Get-ChildItem -LiteralPath $directory.FullName -Force | Select-Object -First 1)) {
        throw 'The analysis directory is already in use. Supply an empty working directory for this run.'
    }
    $result = @{ has_processing_errors = $false; forensic_analysis_path = $directory.FullName }
} catch {
    $result = @{ has_processing_errors = $true; exception_messages = @($_.Exception.Message) }
}
$result | ConvertTo-Json -Depth 3
