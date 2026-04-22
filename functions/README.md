# Azure Assessment Functions

This folder contains the backend foundation for the Azure-hosted assessment platform.

## Current Scope

- HTTP API for creating and inspecting assessment jobs
- Queue-triggered worker for asynchronous execution
- Blob-backed artifact upload
- Table-backed job metadata and status tracking
- Table-backed VM pricing cache with live lookup fallback
- Queue-triggered targeted pricing refresh on cache miss
- PowerShell execution wrapper for the existing VM assessment script
- Incremental transition from one implicit assessment tenant to a client-aware control-plane model

## Endpoints

- `POST /api/assessments` - submit a VM assessment job
- `GET /api/assessments` - list recent jobs
- `GET /api/assessments/{jobId}` - get job status and artifact manifest
- `GET /api/assessments/{jobId}/results` - return the completed-job manifest and artifact download links
- `GET /api/assessments/{jobId}/artifacts/{artifactName}` - return metadata and a direct link for one artifact
- `GET /api/context` - return the configured tenant, default assessment subscriptions, and storage target metadata

`POST /api/assessments` now accepts an optional `clientId`, `assessmentProfileId`, and `targetTenantId`. The current worker still runs the existing PowerShell engine, but job metadata and artifact paths are now partitioned by normalized `clientId` so the runtime can evolve toward per-client tenant execution without rewriting the storage layout again.

## Azure Context Model

The cleanest way to outline which tenant, subscription, and storage account this app should use is to separate them into three concerns:

1. Deployment context: the provider tenant, subscription, resource group, and location where the Functions app is deployed.
2. Shared storage context: the subscription, resource group, and storage account used for queues, tables, blobs, and reference/config assets.
3. Assessment scope defaults: the default client identifier plus the subscription IDs the analyzer should inspect when a request does not provide an explicit scope.

Use `azure-context.template.jsonc` in this folder as the human-readable source of truth, and map those values into Function App settings for runtime execution.

Relevant runtime app settings:

- `ASSESSMENT_PROVIDER_TENANT_ID`
- `ASSESSMENT_LOCATION`
- `ASSESSMENT_DEFAULT_CLIENT_ID`
- `ASSESSMENT_DEFAULT_SUBSCRIPTION_IDS`
- `ASSESSMENT_STORAGE_SUBSCRIPTION_ID`
- `ASSESSMENT_STORAGE_RESOURCE_GROUP`
- `ASSESSMENT_STORAGE_ACCOUNT_NAME`
- `ASSESSMENT_QUEUE_NAME`
- `ASSESSMENT_TABLE_NAME`
- `ASSESSMENT_RESULTS_CONTAINER`
- `ASSESSMENT_CONFIG_CONTAINER`
- `ASSESSMENT_REFERENCE_CONTAINER`
- `ASSESSMENT_PRICING_TABLE_NAME`
- `ASSESSMENT_PRICING_REFRESH_QUEUE_NAME`
- `ASSESSMENT_PRICING_CACHE_MAX_AGE_MINUTES`
- `ASSESSMENT_PRICING_LOOKUP_HELPER_PATH`

## Local Development

1. Copy `local.settings.template.json` to `local.settings.json` and fill in real values.
2. Install dependencies with `npm install`.
3. Build with `npm run build`.
4. Start Azurite with `npm run start:storage`.
5. Start Functions locally with `npm start`.

The pricing cache uses Azure Table Storage and a queue-backed refresh path, so Azurite needs to be running for local cache hits, write-through caching, and targeted refresh enqueues.

The local launchers resolve the installed Azurite and Azure Functions Core Tools entry points and prepend the active Node.js directory to `PATH`. This avoids the Windows shell-state issue where Core Tools can start but the Node worker fails to spawn because `node` is not visible to the child process.

The Azurite launcher also enables `--skipApiVersionCheck` because the current Azure Storage SDK versions can emit a newer service API version than Azurite advertises, even though the local emulator behavior needed by this project still works correctly.

The build step also syncs the PowerShell analyzer assets into `functions/assets/azure-vm-analysis`. That keeps the backend package self-contained for local runs and Azure deployment instead of relying on a sibling folder that would not exist inside the deployed Function App package.

## Notes

- The queue worker currently targets the VM assessment script in [azure-vm-analysis/azure-vm-assessment.ps1](../azure-vm-analysis/azure-vm-assessment.ps1).
- Pricing lookups now prefer the Functions pricing cache helper, which reads Azure Table Storage first and falls back to the Azure Retail Prices API on cache miss.
- Cache misses are written through immediately and also enqueue a targeted background refresh for the same region and SKU key.
- Blob-backed config support is implemented through `configBlobPath` in the request payload.
- Result endpoints generate short-lived read links when the storage connection includes a shared key; otherwise they fall back to a direct blob URL shape and blob path metadata.
- This remains the backend-first phase. The frontend application and full client-registry onboarding workflow will be added on top of this contract.