# Azure Assessment Deployment Plan

Status: In Progress

## Scope

Implement the pricing-cache delivery slice for the Azure assessment platform.

This implementation pass keeps the existing Azure Functions backend and VM assessment workflow, but replaces live-only VM pricing lookups with a cache-first model backed by Azure Table Storage and targeted queue-driven refresh jobs.

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
- VM pricing is still resolved live from the Azure Retail Prices API during each assessment run.
- Recommendation analysis calls the pricing logic repeatedly for candidate SKUs, which multiplies retail API traffic and latency.
- Existing storage primitives already include Azure Tables, blobs, and queue-triggered workers that can host a pricing cache without introducing a second runtime.

## Requirements

Functional requirements:

- Add a cache-first pricing lookup path for VM pricing.
- Use Azure Table Storage as the primary cache for computed pricing models.
- On cache miss, perform a live Azure Retail Prices API lookup, return that result to the current assessment, and write it into the cache.
- On cache miss, also enqueue a targeted refresh job for the exact region and SKU shape that was requested.
- Keep the current assessment flow working locally and in Azure Functions while moving pricing logic toward a service-oriented cache model.

Non-functional requirements:

- Keep the current Functions runtime and storage account model.
- Avoid introducing a broad rewrite of the entire assessment engine in one pass.
- Preserve deterministic pricing behavior by caching the computed pricing model shape that the assessment already consumes.
- Keep the local Functions build and execution flow intact.

## Target Architecture

### Functions Runtime

- Azure Functions continues to host the HTTP API and queue workers.
- A new pricing cache service is added inside the Functions codebase.
- A new queue-triggered worker refreshes one pricing cache entry at a time for a specific region, SKU, OS, and license mode.

### Pricing Cache Model

- Azure Table Storage stores computed pricing models keyed by region, SKU, OS profile, and license mode.
- Queue messages are used to request targeted background refresh for specific pricing keys.
- Live retail API lookups remain available as a fallback, but no assessment path should rely on them as the primary source when a valid cache entry exists.

## Current Implementation Slice

1. Add pricing cache settings, types, and storage helpers in the Functions backend.
2. Implement a cache-aware pricing service that reads from Azure Table Storage first and falls back to the Azure Retail Prices API.
3. Add a queue-triggered pricing refresh function for targeted cache population.
4. Update the assessment runtime so pricing requests use the cache-aware helper and cache misses enqueue a targeted refresh job.
5. Update documentation for the new pricing cache behavior and operational settings.

## Validation Strategy

- Build the Functions project after each implementation slice.
- Run a focused pricing-helper validation for a known region and SKU.
- Confirm cache hit, miss, write-through, and queue-enqueue behavior for pricing lookups.
- Confirm the VM assessment workflow still produces pricing-backed outputs after the cache integration.

## Decisions

- Azure Table Storage is the first persistence layer for computed pricing cache entries.
- The cache will store the computed pricing model consumed by the assessment workflow, not the raw retail API payload.
- Cache misses will still return live pricing when available, then immediately write through to the cache.
- Cache misses will also enqueue a targeted refresh job for the same pricing key.
- SKU/spec caching remains a follow-up concern after pricing cache integration is working.

## Status Tracking

- Plan approved by user: Yes
- Pricing cache implementation started: Yes
- Cache-aware pricing service started: No
- Pricing refresh worker started: No
- Ready for validation: No