# Fusion workflow and archive collection

These diagrams show the Fusion bindings for the current scripts. The [June 2025 diagrams](https://github.com/alexandruhera/crowdstrike-hindsight-soar/blob/2fb6bf7/docs/workflow.md) document the original deployment. The upstream workflow owns the directory, loop limit, retrieval and cleanup.

## From trigger to collection

```mermaid
flowchart TD
    accTitle: Launching a Windows Hindsight collection
    accDescr: Fusion validates Windows, prepares a dedicated directory and uploads Hindsight. Processing selects profiles and either starts work, returns no match or reports failure.
    trigger["On-demand sensor, browser, format and optional days"] --> device{"Windows target?"}
    device -->|Yes| prepare["Prepare the upstream execution directory"]
    device -->|No| stop["End with the platform outcome"]
    prepare -->|Success| put["Put the pinned Hindsight executable"]
    put -->|Success| start["Run processing and select profiles"]
    start -->|started| loop["Pass run ID and expected files into the poll loop"]
    start -->|no_match| empty["Notify analyst and finish without an archive"]
    start -->|failed| error["Report failure"]
    prepare -->|Failure| error
    put -->|Failure| error
```

Fusion passes optional days only to processing. Processing returns promptly after launching background work. Keep the same run ID and list of expected files for every collection attempt. The absence of qualifying profiles is a valid result to show the analyst.

## Polling and retrieval

```mermaid
flowchart TD
    accTitle: Poll and retrieve a verified archive
    accDescr: Collection checks each worker's completion marker for this run. Fusion retries pending work within its budget, reports failure or timeout, and retrieves a verified archive on ready.
    poll["Invoke collection once"] --> state{"Collection status"}
    state -->|pending| budget{"Time and attempts remain?"}
    budget -->|Yes| sleep["Sleep in Fusion"]
    sleep --> poll
    budget -->|No| retain["Report outcome and retain the run directory"]
    state -->|failed| retain
    state -->|ready| get["Get the verified ZIP"]
    get -->|Retrieval failed| retain
    get -->|Retrieved| notify["Record retrieval and notify the analyst"]
    notify --> cleanup["Clean up the run directory"]
```

A result filename may appear before Hindsight finishes writing. The collector checks completion records for the same run and verifies the archive before returning its path. Use an explicit success branch after the loop. Reaching the iteration or time limit also exits a loop and needs its own terminal outcome. [Operator setup and field mappings](../README.md)
