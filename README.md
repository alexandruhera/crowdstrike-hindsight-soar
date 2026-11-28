# Hindsight for CrowdStrike Falcon Fusion

Run authorized browser forensics on a Windows endpoint through Falcon Fusion and Real Time Response (RTR). The workflow launches the [Hindsight browser artifact parser](https://github.com/obsidianforensics/hindsight) for the selected browser and retrieves a ZIP of the resulting reports through Falcon. Slack can report run status when configured.

- [Set up the workflow and run a first test](docs/setup.md)
- [Understand the workflow and troubleshoot a run](docs/workflow.md)

## Repository layout

| Path | Contents |
| --- | --- |
| [`scripts/`](scripts/) | Standalone PowerShell entry points for preparation, processing, and collection |
| [`schemas/`](schemas/) | Fusion trigger schema and script input/output schemas |
| [`docs/`](docs/) | Setup, validation, and troubleshooting |
| [`tests/`](tests/) | PowerShell regression checks |

## Trigger inputs

| Field | Value |
| --- | --- |
| `deviceID` | Falcon sensor ID, typically a 32-character hexadecimal value |
| `selected_browser` | Google Chrome, Microsoft Edge, or Brave |
| `output_format` | `xlsx`, `jsonl`, or `sqlite` |

See the [trigger schema](schemas/trigger-input.schema.json) for validation and defaults.

## Run the regression checks

From the repository root, run:

```sh
pwsh -NoProfile -File tests/reliability.ps1
```

The tests use temporary files and mock Windows profile discovery and process launch. Use the [first-run checklist](docs/setup.md#first-test-run) to validate the deployed workflow in Falcon.
