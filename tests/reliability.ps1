$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$root = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
$null = New-Item -Path $root -ItemType Directory
$failures = [Collections.Generic.List[string]]::new()

function Assert-Case($name, [scriptblock]$test) {
    try {
        & $test
        Write-Host "PASS $name"
    } catch {
        $failures.Add($name)
        Write-Host "FAIL ${name}: $_"
    }
}

try {
    $prep = Join-Path $repo 'scripts/prepare.ps1'
    $collect = Join-Path $repo 'scripts/collect.ps1'
    $directory = Join-Path $root 'run'
    $prepInput = @{ forensic_analysis_path = $directory } | ConvertTo-Json -Compress
    $result = & $prep $prepInput | ConvertFrom-Json
    if ($result.has_processing_errors) { throw 'Initial preparation failed' }

    Assert-Case 'Existing directory is protected' {
        $sentinel = Join-Path $directory 'evidence.txt'
        Set-Content -LiteralPath $sentinel -Value 'preserve'
        $result = & $prep $prepInput | ConvertFrom-Json
        if (!$result.has_processing_errors -or !(Test-Path -LiteralPath $sentinel)) {
            throw 'Preparation must report a conflict and preserve the existing file'
        }
    }

    $processing = Join-Path $repo 'scripts/process.ps1'
    $userProfile = Join-Path $root 'test-user'
    $browserData = Join-Path $userProfile 'AppData/Local/Google/Chrome/User Data'
    $null = New-Item -Path $browserData -ItemType Directory -Force
    $processingInput = @{
        forensic_analysis_path = $directory
        forensic_tool_path = 'hindsight.exe'
        system_hostname = 'test-host'
        selected_browser = 'Google Chrome'
        output_format = 'jsonl'
    } | ConvertTo-Json -Compress

    function Get-CimInstance($className) {
        if ($className -eq 'Win32_ComputerSystem') {
            return @{ UserName = 'DOMAIN\test-user' }
        }
        [pscustomobject]@{ LocalPath = $userProfile }
    }

    Assert-Case 'No matching profiles produces a targeted error' {
        function Start-Process { throw 'Start-Process must not run' }
        $result = & $processing $processingInput | ConvertFrom-Json
        if (!$result.has_processing_errors -or $result.exception_messages[0] -notlike 'No matching browser profiles*') {
            throw "Unexpected response: $($result.exception_messages)"
        }
    }

    $null = New-Item -Path (Join-Path $browserData 'Default') -ItemType Directory
    Assert-Case 'Launch failure is returned to Fusion' {
        function Start-Process { throw 'simulated launch failure' }
        $result = & $processing $processingInput | ConvertFrom-Json
        if (!$result.has_processing_errors -or $result.exception_messages[0] -ne 'simulated launch failure') {
            throw "Unexpected response: $($result.exception_messages)"
        }
    }

    Assert-Case 'Single profile returns an array and writes the process record' {
        function Start-Process { Get-Process -Id $PID }
        $result = & $processing $processingInput | ConvertFrom-Json
        if ($result.has_processing_errors -or $result.forensic_results -isnot [array] -or
            $result.forensic_results.Count -ne 1) {
            throw "Unexpected response: $($result.exception_messages)"
        }
        $recordPath = Join-Path $directory "hindsight-$($result.analysis_timestamp).json"
        $record = (Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json).processes[0]
        if ($record.id -ne $PID -or $record.output -ne $result.forensic_results[0]) {
            throw 'Process record does not match the returned result file'
        }
    }

    $file = Join-Path $directory 'result.jsonl'
    Set-Content -LiteralPath $file -Value '{}'
    $inputData = @{
        forensic_analysis_path = $directory
        system_hostname = 'test-host'
        analysis_timestamp = 'test-run'
        selected_browser = 'Google Chrome'
        forensic_results = @($file)
    }
    $manifest = Join-Path $directory 'hindsight-test-run.json'

    Assert-Case 'Existing file without process records is rejected' {
        $result = & $collect ($inputData | ConvertTo-Json -Compress) | ConvertFrom-Json
        if (!$result.has_processing_errors) { throw 'Result was accepted without process records' }
    }

    Assert-Case 'Live process prevents collection' {
        $running = Get-Process -Id $PID
        @{
            processes = @(@{ id = $PID; start_ticks = $running.StartTime.ToUniversalTime().Ticks.ToString(); output = $file })
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifest
        $result = & $collect ($inputData | ConvertTo-Json -Compress) | ConvertFrom-Json
        if (!$result.has_processing_errors) { throw 'Result was accepted while its process was active' }
    }

    @{
        processes = @(@{ id = 2147483647; start_ticks = '1'; output = $file })
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifest

    Assert-Case 'Exited process and existing file produce a ZIP' {
        $result = & $collect ($inputData | ConvertTo-Json -Compress) | ConvertFrom-Json
        if ($result.has_processing_errors -or !(Test-Path -LiteralPath $result.zip_file_path)) {
            throw "Collection failed: $($result.exception_messages)"
        }
    }

    Assert-Case 'Failed compression cannot reuse an old ZIP' {
        function Compress-Archive { Write-Error 'simulated compression failure' }
        $result = & $collect ($inputData | ConvertTo-Json -Compress) | ConvertFrom-Json
        if (!$result.has_processing_errors -or $result.zip_file_path) { throw 'Collection reported success' }
    }

    Assert-Case 'Missing ZIP after compression is an error' {
        function Compress-Archive {}
        $inputData.analysis_timestamp = 'missing-zip'
        Copy-Item -LiteralPath $manifest -Destination (Join-Path $directory 'hindsight-missing-zip.json')
        $result = & $collect ($inputData | ConvertTo-Json -Compress) | ConvertFrom-Json
        if (!$result.has_processing_errors -or $result.zip_file_path) { throw 'Collection reported success' }
    }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}

if ($failures.Count) { throw "Failed $($failures.Count) checks" }
