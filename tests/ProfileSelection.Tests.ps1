BeforeAll {
    $processingScript = Join-Path $PSScriptRoot '../001-hindsight-processing.ps1'
    $clock = [DateTime]::Parse('2025-03-09T12:00:00Z').ToUniversalTime()
    $isWindowsHost = [Environment]::OSVersion.Platform -eq 'Win32NT'
    $toolDirectory = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'tool')
    $testTool = Join-Path $toolDirectory.FullName 'hindsight.exe'
    if ($isWindowsHost) {
        $source = Join-Path $TestDrive 'testtool.cs'
        @'
using System;
using System.IO;
class TestTool {
    static int Main(string[] args) {
        string profile = args[Array.IndexOf(args, "-i") + 1];
        string output = args[Array.IndexOf(args, "-o") + 1];
        if (File.Exists(Path.Combine(profile, "fail"))) return 11;
        File.WriteAllText(output + ".jsonl", File.Exists(Path.Combine(profile, "invalid")) ? "broken" : "{\"ok\":true}\n");
        return 0;
    }
}
'@ | Set-Content -LiteralPath $source
        $compiler = Join-Path $env:SystemRoot 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
        & $compiler /nologo "/out:$testTool" $source
        if ($LASTEXITCODE -ne 0) { throw 'Could not compile the test executable.' }
    } else {
        @'
#!/bin/sh
test -f "$2/fail" && exit 11
if test -f "$2/invalid"; then echo broken; else echo '{"ok":true}'; fi > "$4.jsonl"
'@ | Set-Content -LiteralPath $testTool
        & chmod +x $testTool
    }

    function Invoke-TestProcessing($payload, [switch]$MissingSid) {
        function Get-Date { $clock }
        function Get-CimInstance($ClassName, $Filter) {
            $sid = 'S-1-5-21-111-222-333-1001'
            switch ($ClassName) {
                'Win32_ComputerSystem' { [pscustomobject]@{ UserName = 'domain\analyst' } }
                'Win32_UserAccount' {
                    if ($Filter -ne "Domain = 'domain' AND Name = 'analyst'") { throw 'Expected a fully qualified lookup.' }
                    if (-not $MissingSid) { [pscustomobject]@{ Domain='domain'; Name='analyst'; SID=$sid } }
                }
                'Win32_UserProfile' {
                    if ($Filter -eq "SID = '$sid'") { [pscustomobject]@{ LocalPath=$userRoot; SID=$sid } }
                    else { [pscustomobject]@{ LocalPath=(Join-Path $fixture 'analyst'); SID='S-1-5-21-444-555-666-1001' } }
                }
                default { throw "Unexpected CIM class: $ClassName" }
            }
        }
        & $processingScript -json_input ($payload | ConvertTo-Json) | ConvertFrom-Json
    }
    function Add-TestProfile($name, $modified) {
        $dir = [IO.Directory]::CreateDirectory((Join-Path $browserRoot $name)).FullName
        if ($null -ne $modified) {
            $history = Join-Path $dir 'History'
            [IO.File]::WriteAllText($history, '')
            [IO.File]::SetLastWriteTimeUtc($history, $modified)
        }
        $dir
    }
    function Wait-TestMarkers($result) {
        foreach ($file in $result.forensic_results) {
            $deadline = [datetime]::UtcNow.AddSeconds(30)
            while (-not [IO.File]::Exists("$file.status.json") -and [datetime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 100
            }
            Get-Content -LiteralPath "$file.status.json" -Raw -ErrorAction Stop | ConvertFrom-Json
        }
    }
}
Describe 'Hindsight processing action' {
    BeforeEach {
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $userRoot = Join-Path $fixture 'analyst.DOMAIN'
        $browserRoot = Join-Path $userRoot 'AppData/Local/Google/Chrome/User Data'
        [void][IO.Directory]::CreateDirectory($browserRoot)
        $working = [IO.Directory]::CreateDirectory((Join-Path $fixture 'case [1]')).FullName
        $exe = Join-Path $working 'hindsight.exe'
        [IO.File]::Copy($testTool, $exe)
        $payload = @{forensic_analysis_path=$working; forensic_tool_path=$exe; selected_browser='Google Chrome'; output_format='jsonl'; system_hostname='PC-12'}
    }
    It 'uses an inclusive UTC cutoff across recent, stale, missing and unrecognised profiles' {
        $null = Add-TestProfile 'Default' $clock.AddDays(-7)
        $null = Add-TestProfile 'Profile 1' $clock.AddDays(-7).AddSeconds(-1)
        $null = Add-TestProfile 'Profile 2' $null
        $null = Add-TestProfile 'Guest Profile' $clock
        $payload.profile_history_days = 7
        $r = Invoke-TestProcessing $payload
        $r.processing_status | Should -Be 'started'
        @($r.browser_profile_names) | Should -Be @('Default')
        $r.run_id | Should -Match '^[0-9a-f]{32}$'
        $r.forensic_results[0] | Should -Match $r.run_id
        $marker = Wait-TestMarkers $r
        $marker.run_id | Should -Be $r.run_id
        $marker.status | Should -Be 'ready'
    }
    It 'keeps unfiltered profiles and reports nonzero exit and corrupt results per profile' {
        $a = Add-TestProfile 'Default' $null
        $b = Add-TestProfile 'Profile 1' $clock.AddDays(-50)
        [IO.File]::WriteAllText((Join-Path $a 'fail'), '')
        [IO.File]::WriteAllText((Join-Path $b 'invalid'), '')
        $r = Invoke-TestProcessing $payload
        $r.processing_status | Should -Be 'started'
        $r.forensic_results.Count | Should -Be 2
        $markers = @(Wait-TestMarkers $r)
        @($markers | Where-Object status -eq 'failed').Count | Should -Be 2
        ($markers.message -join ' ') | Should -Match '11'
    }
    It 'fails closed when the full account cannot be resolved even if a same-named profile exists' {
        $other = Join-Path $fixture 'analyst/AppData/Local/Google/Chrome/User Data/Default'
        [void][IO.Directory]::CreateDirectory($other)
        $r = Invoke-TestProcessing $payload -MissingSid
        $r.processing_status | Should -Be 'failed'
        $r.exception_messages[0] | Should -Match 'SID'
        @(Get-ChildItem -LiteralPath $working -Filter '*.status.json').Count | Should -Be 0
    }
    It 'returns an explicit no-match for zero candidates' {
        $r = Invoke-TestProcessing $payload
        $r.processing_status | Should -Be 'no_match'
        $r.forensic_results.Count | Should -Be 0
    }
    It 'rejects a file access failure without launching a partial selection' {
        $null = Add-TestProfile 'Default' $clock
        $denied = Join-Path (Add-TestProfile 'Profile 1' $clock) 'History'
        Mock Get-Item { throw [UnauthorizedAccessException]::new('Access to History was denied.') } -ParameterFilter {
            $LiteralPath -eq $denied
        }
        $payload.profile_history_days = 7
        $r = Invoke-TestProcessing $payload
        $r.processing_status | Should -Be 'failed'
        $r.exception_messages[0] | Should -Match 'denied'
        @(Get-ChildItem -LiteralPath $working -Filter '*.status.json').Count | Should -Be 0
    }
    It 'returns failed if the deployed binary is missing' {
        $null = Add-TestProfile 'Default' $clock
        [IO.File]::Delete($exe)
        $r = Invoke-TestProcessing $payload
        $r.processing_status | Should -Be 'failed'
        $r.has_processing_errors | Should -BeTrue
    }
    It 'rejects an invalid days input before launch' -ForEach @(0, -1, 1.5, '2', $null) {
        $null = Add-TestProfile 'Default' $clock
        $payload.profile_history_days = $_
        $r = Invoke-TestProcessing $payload
        $r.processing_status | Should -Be 'failed'
        $r.has_processing_errors | Should -BeTrue
    }
}
