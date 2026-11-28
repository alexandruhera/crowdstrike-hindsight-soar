param (
    [string]$json_input
)

try {
    $json_data = $json_input | ConvertFrom-Json -ErrorAction Stop
    $analysisPath = $json_data.forensic_analysis_path
    if ([string]::IsNullOrWhiteSpace($analysisPath)) {
        throw 'A working directory is required.'
    }

    # An existing directory may belong to another run. Leave it intact.
    $null = New-Item -Path $analysisPath -ItemType Directory -ErrorAction Stop
    $result = @{
        has_processing_errors = $false
        forensic_analysis_path = $analysisPath
    }
} catch {
    $result = @{
        has_processing_errors = $true
        exception_messages = @($_.Exception.Message)
    }
}

$result | ConvertTo-Json -Depth 2
