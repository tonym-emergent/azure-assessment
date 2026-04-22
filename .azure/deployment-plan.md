# Azure Assessment Deployment Plan

Status: In Progress

## Scope

Implement the first delivery slice of the multi-tenant Azure assessment platform with two explicit phases:

- `Bootstrap`: provider-tenant resources, shared identities, Key Vault, storage topology, and client onboarding metadata.
- `Functions/WebApp`: application deployment and runtime execution that consumes Bootstrap outputs without creating identities or shared resources.

This implementation pass starts with Terraform-based Bootstrap and the minimum backend contract changes needed to stop assuming a single implicit tenant context.

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
- Infrastructure is still Bicep-based even though Terraform is now the target provisioning model.
- Storage and job metadata are job-centric, not client-centric.

## Requirements

Functional requirements:

- Move active provisioning to Terraform.
- Deploy the application into a provider-controlled tenant and subscription.
- Allow assessment execution against separate client tenants.
- Standardize onboarding around per-client app registrations or service principals.
- Separate Bootstrap from Functions/WebApp so Bootstrap can be run locally first.

Non-functional requirements:

- Keep the current PowerShell assessment engine in place for early iterations.
- Keep secrets out of source control and app settings where possible.
- Partition artifacts and metadata by client from the start.
- Preserve the working local Functions flow while introducing the new model incrementally.

## Target Architecture

### Bootstrap Phase

- Terraform provisions the provider resource group, shared storage account, Key Vault, Log Analytics, Application Insights, and user-assigned identities.
- Shared storage contains job metadata, client registry metadata, queues, config/reference assets, and result artifacts.
- Key Vault stores references for per-client credentials or certificates.
- Client onboarding persists normalized records that map `clientId` to tenant, subscriptions, and secret references.

### Functions/WebApp Phase

- Azure Functions hosts the API and queue worker.
- The future web app provides operator workflows for client selection, assessment submission, and history.
- Runtime execution resolves client-specific tenant and subscription scope from stored metadata instead of a single global tenant setting.

## Current Implementation Slice

1. Switch the active infrastructure path from Bicep to Terraform in repo configuration.
2. Add the first Terraform Bootstrap foundation for provider-tenant shared resources.
3. Introduce client-aware request and job metadata in the Functions backend.
4. Update documentation so local Bootstrap execution and the provider-versus-client model are explicit.

## Validation Strategy

- Build the Functions project after the contract changes.
- Run `terraform validate` in `infra/` when Terraform is available locally.
- Confirm local Functions endpoints still accept and return assessment jobs.
- Confirm jobs and artifacts now carry a normalized `clientId` even when the caller does not provide one.

## Decisions

- Terraform is the active source of truth for provisioning.
- `azd` may remain for packaging and app deployment, but not for owning shared infrastructure definitions.
- The provider tenant is the control plane.
- Each client tenant will have its own app registration or service principal.
- Shared provider-owned storage is acceptable initially, provided data is partitioned by client.

## Status Tracking

- Plan approved by user: Yes
- Bootstrap Terraform foundation started: Yes
- Client-aware backend contract started: Yes
- Ready for validation: No