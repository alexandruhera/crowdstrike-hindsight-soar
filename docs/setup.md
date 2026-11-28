# Set up Falcon Fusion

## Prerequisites

- Falcon Fusion access to configure and run an on-demand workflow.
- RTR permissions to run scripts, upload the Hindsight executable, retrieve the ZIP, and clean up the run directory.
- An authorized Windows test endpoint with an interactive user and a supported browser profile.
- A Windows executable from the [Hindsight releases](https://github.com/obsidianforensics/hindsight/releases). Use the same build for validation and deployment.
- A Slack webhook and a destination channel if the workflow sends Slack notifications. Keep the webhook in the deployment's secret configuration.

## Register the workflow assets

Use the [trigger schema](../schemas/trigger-input.schema.json) for the on-demand trigger. Register these scripts and their schemas together. If upgrading an existing deployment, update the RTR script contents or repoint Fusion to the new registrations.

| Stage | Script | Inputs | Outputs |
| --- | --- | --- | --- |
| Prepare | [prepare.ps1](../scripts/prepare.ps1) | [Input schema](../schemas/prepare/input.schema.json) | [Output schema](../schemas/prepare/output.schema.json) |
| Process | [process.ps1](../scripts/process.ps1) | [Input schema](../schemas/process/input.schema.json) | [Output schema](../schemas/process/output.schema.json) |
| Collect | [collect.ps1](../scripts/collect.ps1) | [Input schema](../schemas/collect/input.schema.json) | [Output schema](../schemas/collect/output.schema.json) |

The repository supplies scripts and schemas. Assemble the Fusion actions in your tenant or update the existing workflow.

## Wire the actions

1. Look up the sensor and require an online Windows endpoint. Supply an absolute path dedicated to this workflow. Sequential runs can reuse it. Give overlapping runs on the same endpoint separate paths.
2. Pass the directory to Prepare. Prepare deletes any existing contents and recreates the directory. After it succeeds, use the returned `forensic_analysis_path` for the rest of the run. Use RTR Put File to stage `hindsight.exe` in that directory.
3. Pass the directory, the staged executable's full path, the Falcon hostname, and the selected browser and format to Process. Start polling only after Process returns `has_processing_errors: false`.
4. Pass the directory, hostname, browser, and the Process outputs `forensic_results` and `analysis_timestamp` to Collect. The published workflow used a limit of 15 attempts and 15 minutes. On exhaustion, report a timeout and skip retrieval. Only run RTR Get File when Collect returns `has_processing_errors: false` and a `zip_file_path`.
5. After retrieval succeeds, report completion and clean up the directory returned by Prepare. On failure, decide whether the run directory is needed for investigation before removing it. If Slack is configured, route launch, failure, and retrieval outcomes to the appropriate channel.

## First test run

1. Choose an authorized Windows test sensor and a browser with a known interactive-user profile. Start the workflow with `xlsx` and record the Fusion run ID.
2. Check that Prepare returns the run directory and Process returns the expected profile names and output paths. A running Hindsight process should keep the collector in the polling branch.
3. After RTR Get File succeeds, download the ZIP from the Falcon action output. Open it and confirm it contains a readable report for every expected profile. Check that the cleanup step targeted the same directory and that configured Slack messages reflect the final outcome.
4. Exercise a missing-profile case and a polling timeout in the test deployment. Confirm that Fusion skips Get File on failure and preserves the outcome in its run log.

See [troubleshooting](workflow.md#troubleshooting) for where to look when a step fails.
