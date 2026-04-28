# Azure Assessment Functions

This folder contains the Azure Functions backend for queueing VM assessment jobs, running the PowerShell analyzer, and serving result metadata and artifact links.

## What This App Does

- Accepts HTTP requests to create and inspect assessment jobs.
- Stores job state in Azure Table Storage.
- Uploads JSON, CSV, HTML, log, and manifest artifacts to Blob Storage.
- Runs the VM assessment PowerShell script through a queue-triggered worker.
- Caches VM pricing in Table Storage with queue-based targeted refresh on cache miss.
- Caches regional VM SKU/spec catalogs in Table Storage with queue-based refresh and timer-driven bulk refresh.

## Functions

### HTTP Functions

- `submitAssessment` at `POST /api/assessments`
	Creates a VM assessment job and writes a message to the assessment queue.
- `listAssessments` at `GET /api/assessments`
	Lists recent jobs, optionally filtered by `clientId`.
- `getAssessmentStatus` at `GET /api/assessments/{jobId}`
	Returns job status plus manifest data when available.
- `getAssessmentResults` at `GET /api/assessments/{jobId}/results`
	Returns the job record, manifest, and artifact links.
- `getAssessmentArtifact` at `GET /api/assessments/{jobId}/artifacts/{artifactName}`
	Returns metadata and a direct link for one artifact. Valid artifact names are `json`, `csv`, `html`, `log`, and `manifest`.
- `getRuntimeContext` at `GET /api/context`
	Returns configured tenant, default client, default subscriptions, and storage target metadata.

### Background Functions

- `runAssessmentJob`
	Queue-triggered worker that runs the PowerShell VM analyzer and persists artifacts.
- `refreshPricingCache`
	Queue-triggered worker for one pricing cache key.
- `refreshVmSkuCatalog`
	Queue-triggered worker for one region/family VM SKU catalog refresh.
- `scheduleVmSkuCatalogRefresh`
	Timer-triggered worker that enqueues bulk VM SKU catalog refresh jobs for configured target regions and families.

## Request And Response Shape

### Submit An Assessment

Endpoint:

- `POST /api/assessments`

Body:

```json
{
	"tool": "vm",
	"clientId": "contoso-prod",
	"targetTenantId": "00000000-0000-0000-0000-000000000000",
	"subscriptionIds": [
		"11111111-1111-1111-1111-111111111111"
	],
	"vmNames": [
		"vm-app-01",
		"vm-app-02"
	],
	"daysToInspect": 14,
	"configBlobPath": "configs/vm/custom-config.jsonc",
	"refreshAdvisor": false,
	"outputPrefix": "vm-analysis-api",
	"requestedBy": "portal"
}
```

Response:

```json
{
	"jobId": "job-1776880000000-abcd1234",
	"clientId": "contoso-prod",
	"status": "Queued",
	"requestedAt": "2026-04-22T20:00:00.000Z",
	"targetTenantId": "00000000-0000-0000-0000-000000000000",
	"subscriptionIds": [
		"11111111-1111-1111-1111-111111111111"
	],
	"message": "Queued for execution"
}
```

### List Assessments

Examples:

- `GET /api/assessments`
- `GET /api/assessments?clientId=contoso-prod&limit=10`

### Get Status And Results

- `GET /api/assessments/{jobId}` returns the current job state and manifest if one exists.
- `GET /api/assessments/{jobId}/results` returns the completed result envelope with artifact links.
- `GET /api/assessments/{jobId}/artifacts/html` returns the HTML artifact link and metadata only.

## Calling The API

All HTTP functions use `authLevel: function`.

When deployed to Azure, call them with either:

- `?code=<function-key>` on the URL
- `x-functions-key: <function-key>` in the request headers

Examples:

```powershell
$baseUrl = "https://<your-function-app>.azurewebsites.net/api"
$functionKey = "<function-key>"

Invoke-RestMethod `
	-Method Post `
	-Uri "$baseUrl/assessments?code=$functionKey" `
	-ContentType "application/json" `
	-Body (@{
		tool = "vm"
		clientId = "contoso-prod"
		subscriptionIds = @("11111111-1111-1111-1111-111111111111")
		daysToInspect = 14
		requestedBy = "manual-test"
	} | ConvertTo-Json)
```

```powershell
Invoke-RestMethod `
	-Method Get `
	-Uri "$baseUrl/assessments/$jobId/results?code=$functionKey"
```

## Runtime Configuration

Use [local.settings.template.json](local.settings.template.json) as the local baseline and map the same values to Function App settings in Azure.

### Azure Context Settings

- `ASSESSMENT_PROVIDER_TENANT_ID`
- `ASSESSMENT_LOCATION`
- `ASSESSMENT_DEFAULT_CLIENT_ID`
- `ASSESSMENT_DEFAULT_SUBSCRIPTION_IDS`
- `ASSESSMENT_STORAGE_SUBSCRIPTION_ID`
- `ASSESSMENT_STORAGE_RESOURCE_GROUP`
- `ASSESSMENT_STORAGE_ACCOUNT_NAME`

### Core Job Storage Settings

- `AzureWebJobsStorage`
- `ASSESSMENT_QUEUE_NAME`
- `ASSESSMENT_TABLE_NAME`
- `ASSESSMENT_RESULTS_CONTAINER`
- `ASSESSMENT_CONFIG_CONTAINER`
- `ASSESSMENT_REFERENCE_CONTAINER`

### Pricing Cache Settings

- `ASSESSMENT_PRICING_TABLE_NAME`
- `ASSESSMENT_PRICING_REFRESH_QUEUE_NAME`
- `ASSESSMENT_PRICING_CACHE_MAX_AGE_MINUTES`
- `ASSESSMENT_PRICING_LOOKUP_HELPER_PATH`

### VM SKU Catalog Cache Settings

- `ASSESSMENT_VM_SKU_TABLE_NAME`
- `ASSESSMENT_VM_SKU_REFRESH_QUEUE_NAME`
- `ASSESSMENT_VM_SKU_CACHE_MAX_AGE_MINUTES`
- `ASSESSMENT_VM_SKU_REFRESH_SCHEDULE`
- `ASSESSMENT_VM_SKU_TARGET_REGIONS`
- `ASSESSMENT_VM_SKU_TARGET_FAMILIES`
- `ASSESSMENT_VM_SKU_LOOKUP_HELPER_PATH`

### Assessment Runner Settings

- `ASSESSMENT_SCRIPT_PATH`
- `ASSESSMENT_DEFAULT_CONFIG_PATH`
- `ASSESSMENT_OUTPUT_PREFIX`

## Local Development

1. Copy [local.settings.template.json](local.settings.template.json) to `local.settings.json`.
2. Fill in the tenant, subscription, and storage metadata placeholders.
3. Install dependencies with `npm install`.
4. Build with `npm run build`.
5. Start Azurite with `npm run start:storage`.
6. Start the Functions host with `npm start`.

Local notes:

- The pricing cache and VM SKU catalog cache both use Table Storage and queue writes, so Azurite must be running when `AzureWebJobsStorage=UseDevelopmentStorage=true`.
- Azurite-generated files are intentionally ignored from git.
- The local launcher scripts resolve installed entry points and prepend the active Node.js path to avoid Windows shell PATH issues.
- The build step syncs analyzer assets into [functions/assets/azure-vm-analysis/azure-vm-assessment.ps1](assets/azure-vm-analysis/azure-vm-assessment.ps1) so the deployed package remains self-contained.

## Internal Scripts

### Runtime Scripts

- [functions/scripts/start-azurite.js](scripts/start-azurite.js)
	Starts Azurite in [functions/.azurite](.azurite) with `--skipApiVersionCheck`.
- [functions/scripts/start-functions-host.js](scripts/start-functions-host.js)
	Starts Azure Functions Core Tools with the current Node installation added to `PATH`.
- [functions/scripts/sync-analyzer-assets.js](scripts/sync-analyzer-assets.js)
	Copies the PowerShell analyzer and related assets into the deployable Functions package.

### Helper CLIs

- [functions/src/scripts/pricingLookupCli.ts](src/scripts/pricingLookupCli.ts)
	Cache-aware pricing lookup used by the PowerShell analyzer.
- [functions/src/scripts/vmSkuCatalogLookupCli.ts](src/scripts/vmSkuCatalogLookupCli.ts)
	Cache-aware VM SKU/spec catalog lookup used by the PowerShell analyzer.

## How The VM Assessment Flow Works

1. `submitAssessment` validates the request and creates a job row.
2. The job ID is written to the assessment queue.
3. `runAssessmentJob` dequeues the job and runs the PowerShell analyzer.
4. The analyzer uses the Functions helper CLIs for pricing and VM SKU catalog lookups when available.
5. Cache misses do a live lookup, write through to table storage, and enqueue a targeted refresh job.
6. Artifacts are uploaded to Blob Storage and the job row is updated to `Completed` or `Failed`.

## Important Notes

- The current analyzer still uses the PowerShell VM assessment engine at [azure-vm-analysis/azure-vm-assessment.ps1](../azure-vm-analysis/azure-vm-assessment.ps1).
- `configBlobPath` lets the API request point at a blob-backed config file instead of requiring inline analyzer settings.
- Artifact endpoints generate SAS links when the storage connection string includes a shared key. Otherwise they fall back to direct blob URL shape plus blob metadata.
- The timer-driven VM SKU catalog refresh does nothing until `ASSESSMENT_VM_SKU_TARGET_REGIONS` is populated.