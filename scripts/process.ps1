param (
    [string]$json_input
)

$browserPaths = @{
    'Google Chrome' = 'AppData\Local\Google\Chrome\User Data'
    'Microsoft Edge' = 'AppData\Local\Microsoft\Edge\User Data'
    'Brave' = 'AppData\Local\BraveSoftware\Brave-Browser\User Data'
}

try {
    $inputData = $json_input | ConvertFrom-Json -ErrorAction Stop
    $analysisPath = $inputData.forensic_analysis_path
    $toolPath = $inputData.forensic_tool_path
    $format = $inputData.output_format
    $browser = $inputData.selected_browser
    $hostname = $inputData.system_hostname

    if (!$browser -or !$browserPaths.ContainsKey($browser)) {
        throw 'Select a supported browser.'
    }
    if ($format -notin @('xlsx', 'jsonl', 'sqlite')) {
        throw 'Select a supported output format.'
    }
    if ($hostname -notmatch '^[a-zA-Z0-9_.-]+$') {
        throw 'A valid hostname is required.'
    }

    # RTR runs under a separate account from the interactive user.
    $username = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName -replace '^.+\\', ''
    if (!$username) {
        throw 'No interactive Windows user was found.'
    }
    $userProfiles = @(Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object {
        $_.LocalPath -and (Split-Path -Leaf $_.LocalPath) -eq $username
    })
    if ($userProfiles.Count -ne 1) {
        throw "Expected one local Windows profile for $username."
    }

    $userDataPath = Join-Path $userProfiles[0].LocalPath $browserPaths[$browser] -ErrorAction Stop
    $profiles = @(Get-ChildItem -LiteralPath $userDataPath -Directory -ErrorAction Stop | Where-Object {
        $_.Name -match '^Default$|^Profile\s\d+$'
    })
    if (!$profiles.Count) {
        throw "No matching browser profiles found for $browser."
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ss-fff')
    $browserName = $browser -replace '\s', '-'
    $processes = foreach ($profile in $profiles) {
        $profileName = $profile.Name -replace '\s', '-'
        $outputBase = Join-Path $analysisPath "$hostname-$browserName-$profileName-$timestamp" -ErrorAction Stop
        $arguments = "-i `"$($profile.FullName)`" -o `"$outputBase`" -f $format -t UTC"
        $process = Start-Process -FilePath $toolPath -ArgumentList $arguments -NoNewWindow -PassThru -ErrorAction Stop
        try {
            $startTicks = $process.StartTime.ToUniversalTime().Ticks.ToString()
        } catch {
            if (!$process.HasExited -or $process.ExitCode -ne 0) { throw }
            $startTicks = '0'
        }
        if ($process.HasExited -and $process.ExitCode -ne 0) {
            throw "Hindsight exited with code $($process.ExitCode) for $($profile.Name)."
        }

        @{
            id = $process.Id
            start_ticks = $startTicks
            output = "$outputBase.$format"
        }
    }

    # Fusion starts polling after this script returns its result.
    $manifestPath = Join-Path $analysisPath "hindsight-$timestamp.json"
    @{ processes = @($processes) } | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $manifestPath -Encoding UTF8 -ErrorAction Stop

    $result = @{
        has_processing_errors = $false
        user_data_path = $userDataPath
        browser_profile_names = @($profiles.Name)
        browser_profile_paths = @($profiles.FullName)
        forensic_results = @($processes.output)
        analysis_timestamp = $timestamp
    }
} catch {
    $result = @{
        has_processing_errors = $true
        exception_messages = @($_.Exception.Message)
    }
}

$result | ConvertTo-Json -Depth 2
