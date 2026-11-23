# Browser forensics with Falcon Fusion SOAR and Hindsight

Use an on-demand Fusion workflow to collect browser artifacts from the signed-in user on a Windows endpoint. Real Time Response (RTR) stages Hindsight and starts processing. Fusion can release the launch action while Hindsight works, poll for a verified archive, and retrieve it through **Get file**. The repository supplies the endpoint actions and JSON schemas. The workflow owner configures the orchestration and notification bindings in Falcon.

## Run a collection

Choose the sensor, browser and output format. Supply the optional number of days to select profiles by the last modification of their Chromium `History` file.

```json
{
  "deviceID": "0123456789abcdef0123456789abcdef",
  "selected_browser": "Google Chrome",
  "output_format": "jsonl",
  "profile_history_days": 7
}
```

| Input | Accepted values | Effect |
| --- | --- | --- |
| `deviceID` | Falcon sensor ID | Target of the RTR actions |
| `selected_browser` | `Google Chrome`, `Microsoft Edge`, `Brave` | User data directory to search |
| `output_format` | `xlsx`, `jsonl`, `sqlite` | One Hindsight output per selected profile |
| `profile_history_days` | Optional positive integer | Include profiles whose `History` file was modified within the window, including the exact UTC cutoff |

Omit the days field to process all discovered `Default` and `Profile N` directories for the selected browser. The window selects **whole profiles**. A qualifying profile can contain visits older than the window. SQLite can buffer recent writes in a separate journal file, so a stale database timestamp alone is insufficient evidence that a browser was idle. Use an unfiltered run if that distinction matters.

## Configure Fusion

1. Configure an on-demand trigger with [trigger-input.json](trigger-input.json). Use Get device details and require Windows before staging tools. The RTR policy and role need permissions to upload files, run the scripts and retrieve the archive.
2. Register each numbered PowerShell script with its matching input and output JSON schemas. Supply the action input object as JSON through the script's `json_input` parameter. Keep script registrations and schemas together when versioning them.
3. Have the upstream step choose a dedicated, access-controlled working directory for this execution. Pass it to preparation. Use a unique directory per execution on a shared host so simultaneous runs and late workers have independent lifetimes.
4. On preparation success, use RTR Put file to place the verified `hindsight.exe` in the prepared directory. For the pinned v2026.11 Windows artifact the SHA-256 is `2e407bda175ebe6d1daec740a9b24507dcfb4d6a40f47caf6b729b2824ad1135`. Compare the staged upload source with `Get-FileHash -Algorithm SHA256`. [Hindsight release](https://github.com/RyanDFIR/hindsight/releases/tag/v2026.11)
5. Map the inputs below. Branch on the status fields and gate retrieval on `ready`. The historical workflow used 15 attempts within 15 minutes. Inspect the deployed action and set the loop budget for the endpoint population. The action's timeout and Fusion's polling budget are separate settings. [Workflow diagrams and branch behavior](docs/workflow.md)

| Action | Map from upstream | Consume downstream |
| --- | --- | --- |
| Preparation | `forensic_analysis_path` | On success use the returned path for the upload and processing. On error stop and report the messages. |
| Processing | Working directory, staged executable path, system hostname, selected browser, format, optional days | `started` supplies `run_id`, `forensic_results`, and `analysis_timestamp`. A `no_match` result ends the run without retrieval. A `failed` result goes to the error branch. |
| Collection | `run_id`, `forensic_results`, and `analysis_timestamp` from the same launch, plus `forensic_analysis_path`, `system_hostname`, and `selected_browser` | `pending` sleeps and retries collection. `failed` reports the error. Only `ready` supplies a verified `zip_file_path` for Get file. |

## Retrieval and recovery

Retrieve the archive once, record the successful Get file result, then send a completion notification and clean up the execution directory. The operator can download the archive from the completed action in Falcon. Configure Slack with your tenant's connection. Keep notification failure distinct from retrieval failure so a messaging outage cannot discard the retrieval result.

The worker runs as a separate PowerShell process under the endpoint policy. If an expected status file never appears, inspect the launch action and the host’s PowerShell or application-control logs for a blocked worker. Validate the script against your existing policy on the test endpoint.

On loop exhaustion or failed retrieval, record the run ID and working directory and retain outputs for recovery. A collection retry for a run must use its original expected file list. Starting processing again creates a new run. A timed-out worker may still be writing.

**Upgrade an existing workflow** by copying its action bindings to a new workflow version. Add the optional days mapping at the trigger and processing step, pass the run ID and result list to collection, and wire the status branches. Let earlier executions finish against their original collector. A list of paths from the historical processor lacks the completion information required by this collector. The [original workflow and screenshots](https://github.com/alexandruhera/crowdstrike-hindsight-soar/blob/7bf009c/README.md) remain available for comparison.

## Verification

The Windows CI workflow runs Pester under Windows PowerShell 5.1 and PowerShell 7 and checks a synthetic visit in archives produced by the pinned Hindsight executable. [Windows test workflow](.github/workflows/windows-tests.yml) · [Synthetic fixture](tests/hindsight_fixture.py)

Use the repository's Windows tests for the script entry points, file timestamps, asynchronous completion and generated archives. On a Falcon-managed test endpoint, verify a filtered run, an unfiltered run, no matches, a failed worker, loop exhaustion and failed retrieval before enabling the revised bindings. Check the signed-in identity, script policy, Slack result and cleanup order in that tenant. The diagrams document the bindings to configure. A Falcon workflow export is tenant-specific.

Created by [Alexandru Hera](https://www.linkedin.com/in/alexandruhera) using [Hindsight](https://github.com/RyanDFIR/hindsight) and [CrowdStrike RTR](https://developer.crowdstrike.com/foundry/logic-capabilities/rtr-scripts/).
