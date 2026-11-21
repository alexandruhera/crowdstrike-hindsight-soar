param (
    [string]$json_input
)

$json_data = $json_input | ConvertFrom-Json
$forensic_analysis_path = $json_data.forensic_analysis_path
$forensic_tool_path = $json_data.forensic_tool_path
$output_format = $json_data.output_format
$selected_browser = $json_data.selected_browser
$system_hostname = $json_data.system_hostname

$browser_profile_names = @()
$browser_profile_paths = @()
$resolved_user_data_path = $null
$analysis_timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm")
$forensic_results = @()

$has_processing_errors = $false
$exception_messages = @()

$browser_paths = @{
    "Google Chrome" = "AppData\Local\Google\Chrome\User Data"
    "Microsoft Edge" = "AppData\Local\Microsoft\Edge\User Data"
    "Brave" = "AppData\Local\BraveSoftware\Brave-Browser\User Data"
}

# Resolve the interactive user's profile because RTR runs under a separate account.
try {
    $current_user = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName -replace '^.+\\', ''
    $user_profile_path = (Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object { $_.LocalPath -like "*\$current_user" }).LocalPath

    if (-not (Test-Path $user_profile_path)) {
        throw "The user's local profile path does not exist: $user_profile_path"
    }
} catch {
    $exception_messages += $_.Exception.Message
}

$has_processing_errors = [bool]($exception_messages.Count)

if (-not $has_processing_errors) {
    try {
        $browser_user_data_path = Join-Path -Path $user_profile_path -ChildPath $browser_paths[$selected_browser]

        if (-not (Test-Path $browser_user_data_path)) {
            throw "The selected browser's data path does not exist: $browser_user_data_path"
        }

        $resolved_user_data_path = $browser_user_data_path
    } catch {
        $exception_messages += "An error occurred when checking the browser profiel path $_.Exception.Message"
    }
}

$has_processing_errors = [bool]($exception_messages.Count)

if (-not $has_processing_errors) {
    try {
        $detected_profiles = Get-ChildItem -Path $resolved_user_data_path -Directory | Where-Object { $_.Name -match '^Default$|^Profile\s\d+$' }

        foreach ($profile_entry in $detected_profiles) {
            $browser_profile_names += $profile_entry.Name
            $browser_profile_paths += $profile_entry.FullName
        }
    } catch {
        $exception_messages += "An error ocurred when attempting to the browser profile path $_.Exception.Message"
    }
}

$has_processing_errors = [bool]($exception_messages.Count)
if (-not $has_processing_errors) {
    foreach ($index in 0..($browser_profile_names.Count - 1)) {
        $source_profile_path = $browser_profile_paths[$index]
        $cleaned_profile_name = $browser_profile_names[$index] -replace "\s", "-"
        $cleaned_browser_name = $selected_browser -replace "\s", "-"
        $cleaned_forensic_tool_path = $forensic_tool_path -replace "/", "\"

        $forensic_output_base = Join-Path $forensic_analysis_path "${system_hostname}-${cleaned_browser_name}-${cleaned_profile_name}-${analysis_timestamp}"
        $forensic_output_path = "$forensic_output_base.$output_format"

        try {
            # Start Hindsight asynchronously so Fusion can poll for its output.
            Start-Process -FilePath $cleaned_forensic_tool_path `
                -ArgumentList "-i `"$source_profile_path`" -o `"$forensic_output_base`" -f $output_format -t UTC" `
                -NoNewWindow

            $forensic_results += $forensic_output_path
        } catch {
            $exception_messages += $_.Exception.Message
        }
    }
}

$has_processing_errors = [bool]($exception_messages.Count)

if ($has_processing_errors) {
    $json_output = [PSCustomObject]@{
        "has_processing_errors" = $has_processing_errors
        "exception_messages" = $exception_messages
    }
} else {
    $json_output = [PSCustomObject]@{
        "has_processing_errors" = $has_processing_errors
        "user_data_path" = $resolved_user_data_path
        "browser_profile_names" = $browser_profile_names
        "browser_profile_paths" = $browser_profile_paths
        "forensic_results" = $forensic_results
        "analysis_timestamp" = $analysis_timestamp
    }
}

$json_output | ConvertTo-Json -Depth 2
