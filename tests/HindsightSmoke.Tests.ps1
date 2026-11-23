# CI sets HINDSIGHT_SMOKE_EXE to a checksum-verified Windows executable.
Describe 'Processing and collection with Hindsight v2026.11' -Skip:(-not $env:HINDSIGHT_SMOKE_EXE) {
    BeforeAll {
        $repo = Split-Path -Parent $PSScriptRoot
        $fixture = Join-Path $PSScriptRoot 'hindsight_fixture.py'
        $ciHome = Join-Path $TestDrive 'ci-user'
        $browserRoot = Join-Path $ciHome 'AppData\Local\Google\Chrome\User Data'
        python $fixture create (Join-Path $browserRoot 'Default')
        if ($LASTEXITCODE -ne 0) { throw 'Could not create the synthetic profile.' }

        # Supply the interactive identity that an RTR host would normally resolve via CIM.
        function Get-CimInstance($ClassName) {
            switch ($ClassName) {
                'Win32_ComputerSystem' { [pscustomobject]@{ UserName = 'LAB\ci-user' } }
                'Win32_UserProfile'    { [pscustomobject]@{ LocalPath = $ciHome } }
                default                { throw "Unexpected CIM class: $ClassName" }
            }
        }
    }

    It 'archives the synthetic visit as <format>' -ForEach @(
        @{ format = 'jsonl' }, @{ format = 'sqlite' }, @{ format = 'xlsx' }
    ) {
        $runDirectory = Join-Path $TestDrive "output $format"
        $prepare = Join-Path $repo '001-hindsight-preparation.ps1'
        $prepareInput = @{ forensic_analysis_path = $runDirectory } | ConvertTo-Json
        $prepared = & $prepare -json_input $prepareInput | ConvertFrom-Json
        $prepared.has_processing_errors | Should -BeFalse

        $binary = Join-Path $runDirectory 'hindsight.exe'
        Copy-Item -LiteralPath $env:HINDSIGHT_SMOKE_EXE -Destination $binary
        $request = @{
            forensic_analysis_path = $runDirectory
            forensic_tool_path     = $binary
            output_format          = $format
            selected_browser       = 'Google Chrome'
            system_hostname        = 'CI-HOST'
            profile_history_days   = 7
        }
        $processing = Join-Path $repo '001-hindsight-processing.ps1'
        $started = & $processing -json_input ($request | ConvertTo-Json) | ConvertFrom-Json
        $started.processing_status | Should -Be 'started' -Because ($started | ConvertTo-Json -Compress)
        $started.forensic_results.Count | Should -Be 1
        $collectionInput = @{
            run_id                = $started.run_id
            forensic_analysis_path = $runDirectory
            forensic_results      = $started.forensic_results
            analysis_timestamp    = $started.analysis_timestamp
            selected_browser      = $request.selected_browser
            system_hostname       = $request.system_hostname
        } | ConvertTo-Json
        $collection = Join-Path $repo '001-hindsight-collection.ps1'
        $deadline = [datetime]::UtcNow.AddMinutes(3)
        do {
            $attempt = & $collection -json_input $collectionInput | ConvertFrom-Json
            if ($attempt.collection_status -ne 'pending') { break }
            Start-Sleep -Seconds 1
        } while ([datetime]::UtcNow -lt $deadline)

        $attempt.collection_status | Should -Be 'ready' -Because ($attempt | ConvertTo-Json -Compress)
        python $fixture verify $attempt.zip_file_path $format
        $LASTEXITCODE | Should -Be 0
    }
}
