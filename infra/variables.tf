variable "environment_name" {
  description = "Short environment name used in resource naming."
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Azure region for provider-hosted Bootstrap resources."
  type        = string
  default     = "eastus"
}

variable "provider_tenant_id" {
  description = "Tenant ID where the provider-hosted control plane resources are deployed."
  type        = string
}

variable "provider_subscription_id" {
  description = "Subscription ID where the provider-hosted control plane resources are deployed."
  type        = string
}

variable "resource_group_name" {
  description = "Optional resource group name override for the Bootstrap foundation."
  type        = string
  default     = null
}

variable "storage_account_name" {
  description = "Optional storage account name override for shared assessment storage."
  type        = string
  default     = null
}

variable "key_vault_name" {
  description = "Optional Key Vault name override for provider-managed secrets."
  type        = string
  default     = null
}

variable "application_insights_name" {
  description = "Optional Application Insights resource name override."
  type        = string
  default     = null
}

variable "log_analytics_workspace_name" {
  description = "Optional Log Analytics workspace name override."
  type        = string
  default     = null
}

variable "assessment_default_subscription_ids" {
  description = "Default Azure subscriptions the assessment platform should inspect when a request does not provide explicit scope."
  type        = list(string)
  default     = []
}

variable "assessment_queue_name" {
  description = "Queue used for asynchronous assessment jobs."
  type        = string
  default     = "assessment-jobs"
}

variable "assessment_jobs_table_name" {
  description = "Table used for job metadata and status tracking."
  type        = string
  default     = "assessmentjobs"
}

variable "assessment_clients_table_name" {
  description = "Table used for normalized client registration metadata."
  type        = string
  default     = "assessmentclients"
}

variable "assessment_client_subscriptions_table_name" {
  description = "Table used for client-to-subscription bindings."
  type        = string
  default     = "clientsubscriptions"
}

variable "assessment_results_container_name" {
  description = "Blob container for generated assessment artifacts."
  type        = string
  default     = "assessment-results"
}

variable "assessment_config_container_name" {
  description = "Blob container for assessment configuration documents."
  type        = string
  default     = "assessment-config"
}

variable "assessment_reference_container_name" {
  description = "Blob container for static reference assets."
  type        = string
  default     = "assessment-reference"
}

variable "assessment_bootstrap_container_name" {
  description = "Blob container for Bootstrap manifests and onboarding exports."
  type        = string
  default     = "assessment-bootstrap"
}

variable "storage_account_replication_type" {
  description = "Replication type for the shared provider storage account."
  type        = string
  default     = "LRS"
}

variable "key_vault_sku_name" {
  description = "SKU for the provider-managed Key Vault."
  type        = string
  default     = "standard"
}

variable "tags" {
  description = "Tags applied to all Bootstrap resources."
  type        = map(string)
  default     = {}
}