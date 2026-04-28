# Azure Assessment Deployment Plan

Status: In Progress

## Scope

Implement the cache-backed pricing and VM SKU/spec delivery slice for the Azure assessment platform.

This implementation pass keeps the existing Azure Functions backend and VM assessment workflow, but replaces live-only VM pricing and VM SKU/spec lookups with cache-first models backed by Azure Table Storage and targeted queue-driven refresh jobs.

## Current Workspace Assessment

Mode: MODIFY

Existing assets:

- [README.md](README.md)
- [azure.yaml](azure.yaml)
- [infra/main.bicep](infra/main.bicep)
- [infra/main.parameters.json](infra/main.parameters.json)
- [azure-vm-analysis/azure-vm-assessment.ps1](azure-vm-analysis/azure-vm-assessment.ps1)
- [functions/](functions/)

Current state:

- The Functions backend is working locally, but it assumes one deployment tenant and one ambient Azure CLI context.
- VM pricing was previously resolved live from the Azure Retail Prices API during each assessment run.
- Regional VM SKU/spec catalogs were previously resolved live through `az vm list-skus` during each assessment run.
- Recommendation analysis calls the pricing logic and candidate SKU catalog repeatedly, which multiplies retail API traffic, Azure CLI calls, and latency.
- Existing storage primitives already include Azure Tables, blobs, and queue-triggered workers that can host a pricing cache without introducing a second runtime.

## Requirements

Functional requirements:

- Add a cache-first pricing lookup path for VM pricing.
- Add a cache-first regional VM SKU/spec catalog lookup path.
- Use Azure Table Storage as the primary cache for computed pricing models and regional VM SKU/spec catalogs.
- On cache miss, perform a live Azure Retail Prices API lookup or Azure CLI `vm list-skus` lookup, return that result to the current assessment, and write it into the cache.
- On cache miss, also enqueue a targeted refresh job for the exact pricing key or region/family catalog that was requested.
- Add a timer-driven bulk VM SKU/spec refresh path for configured regions and families.
- Keep the current assessment flow working locally and in Azure Functions while moving pricing logic toward a service-oriented cache model.

Non-functional requirements:

- Keep the current Functions runtime and storage account model.
- Avoid introducing a broad rewrite of the entire assessment engine in one pass.
- Preserve deterministic pricing behavior by caching the computed pricing model shape that the assessment already consumes.
- Keep the local Functions build and execution flow intact.

## Target Architecture

### Functions Runtime

- Azure Functions continues to host the HTTP API and queue workers.
- A pricing cache service is added inside the Functions codebase.
- A VM SKU/spec catalog cache service is added inside the Functions codebase.
- Queue-triggered workers refresh one pricing key or one region/family VM SKU catalog at a time.
- A timer-triggered worker enqueues bulk VM SKU/spec refresh jobs for configured regions and families.

### Pricing Cache Model

- Azure Table Storage stores computed pricing models keyed by region, SKU, OS profile, and license mode.
- Queue messages are used to request targeted background refresh for specific pricing keys.
- Live retail API lookups remain available as a fallback, but no assessment path should rely on them as the primary source when a valid cache entry exists.

### VM SKU Catalog Cache Model

- Azure Table Storage stores one metadata row per location/family selection plus one row per SKU entry.
- Queue messages are used to request targeted background refresh for a location and family set.
- A timer trigger fans out scheduled refresh jobs for configured target regions and families.
- Live `az vm list-skus` lookups remain available as a fallback, but the assessment path should prefer cached regional catalogs when available.

## Current Implementation Slice

1. Add pricing cache and VM SKU catalog cache settings, types, and storage helpers in the Functions backend.
2. Implement cache-aware pricing and VM SKU catalog services that read from Azure Table Storage first and fall back to live lookups.
3. Add queue-triggered pricing and VM SKU catalog refresh functions for targeted cache population.
4. Add a timer-triggered VM SKU catalog scheduler for configured regions and families.
5. Update the assessment runtime so pricing and VM SKU catalog requests use the cache-aware helpers and cache misses enqueue targeted refresh jobs.
6. Update documentation for the new cache behavior, scheduling, and operational settings.

## Validation Strategy

- Build the Functions project after each implementation slice.
- Run a focused pricing-helper validation for a known region and SKU.
- Run a focused VM SKU catalog helper validation for a known region and family set.
- Confirm cache hit, miss, write-through, and queue-enqueue behavior for pricing and VM SKU catalog lookups.
- Confirm the VM assessment workflow still produces pricing-backed and catalog-backed outputs after the cache integration.

## Decisions

- Azure Table Storage is the first persistence layer for computed pricing cache entries.
- Azure Table Storage is also the first persistence layer for cached VM SKU/spec catalogs.
- The cache will store the computed pricing model consumed by the assessment workflow, not the raw retail API payload.
- The VM SKU/spec cache will store normalized recommendation inputs, not the raw `az vm list-skus` payload.
- Cache misses will still return live pricing when available, then immediately write through to the cache.
- Cache misses will also enqueue a targeted refresh job for the same pricing key or VM SKU catalog selection.
- Scheduled VM SKU/spec refresh is driven by configured target regions and families.

## Status Tracking

- Plan approved by user: Yes
- Pricing cache implementation started: Yes
- VM SKU/spec cache implementation started: Yes
- Cache-aware pricing service started: Yes
- Pricing refresh worker started: Yes
- VM SKU/spec refresh worker started: Yes
- VM SKU/spec scheduler started: Yes
- Ready for validation: No