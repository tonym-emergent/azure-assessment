# Terraform Bootstrap

This folder now owns the first Bootstrap phase for the Azure assessment platform.

## Current Scope

- Provider-tenant resource group
- Shared Storage account for queues, tables, config, references, Bootstrap exports, and result artifacts
- Provider-managed Key Vault for per-client credential references
- Shared monitoring foundation with Log Analytics and Application Insights
- User-assigned identities reserved for Bootstrap automation and the later runtime phase

The Function App and future web app are intentionally not provisioned in this first slice. They belong to the `Functions/WebApp` phase and should consume the outputs produced here rather than re-owning shared resources.

## Local Bootstrap Workflow

1. Copy `terraform.tfvars.example` to a local tfvars file and fill in the provider tenant and subscription.
2. Authenticate to the provider tenant locally with Azure CLI.
3. Run `terraform init` in this folder.
4. Run `terraform validate`.
5. Run `terraform plan -var-file=<your-file>.tfvars`.

## Notes

- `main.bicep` and `main.parameters.json` are retained temporarily as migration references only.
- The onboarding workflow for creating per-client app registrations or service principals is the next Bootstrap increment. This first slice provisions the storage, Key Vault, and identities that workflow will use.