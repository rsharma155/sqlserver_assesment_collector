# Changelog

## Unreleased

- Added `Invoke-SqlAssessmentSuite.ps1` as the consolidated interactive and unattended entry point.
- Added normalized HTML, Excel, and Both output selection across all three tools.
- Added optional Upgrade Advisor JSON and SARIF exports without repeating collection.
- Added timestamped run folders, a suite log, JSON manifest, normalized result, and exit codes.
- Replaced the assessment collectors' dbatools dependency with a shared ADO.NET SQL client.
- Added guaranteed assessment connection cleanup on successful and failed runs.
- Added preflight validation for selected-engine assets, JSON rules, Excel dependencies, and output permissions.
- Added actual assessed database names to assessment results.
- Added Pester static and Upgrade Advisor demo integration tests.
- Added opt-in live Pester coverage for both assessment variants using process-scoped environment variables.
- Fixed the lightweight collector's handling of the shared `DatabaseFilter` SQL token; lightweight instance queries remain intentionally instance-wide.
- Improved trap rethrowing so collector failures preserve the original diagnostic instead of reporting only `ScriptHalted`.

### Migration note

Existing collector commands remain available. New scripts and scheduled jobs should call `Invoke-SqlAssessmentSuite.ps1`. The consolidated command creates a timestamped child directory under `-OutputPath`; existing direct engine invocations continue to use their original output behavior.
