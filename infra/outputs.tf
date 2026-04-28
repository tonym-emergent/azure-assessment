output "provider_tenant_id" {
  description = "Provider tenant that hosts the shared control plane."
  value       = var.provider_tenant_id
}

output "provider_subscription_id" {
  description = "Provider subscription that hosts the shared control plane."
  value       = var.provider_subscription_id
}

output "resource_group_name" {
  description = "Provider resource group for shared Bootstrap resources."
  value       = azurerm_resource_group.bootstrap.name
}

output "application_insights_connection_string" {
  description = "Application Insights connection string for later Functions and WebApp deployment phases."
  value       = azurerm_application_insights.bootstrap.connection_string
  sensitive   = true
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for monitoring configuration."
  value       = azurerm_log_analytics_workspace.bootstrap.id
}

output "storage_account_name" {
  description = "Shared provider-owned storage account name."
  value       = azurerm_storage_account.bootstrap.name
}

output "assessment_results_container_name" {
  description = "Blob container for generated assessment artifacts."
  value       = var.assessment_results_container_name
}

output "assessment_config_container_name" {
  description = "Blob container for assessment configuration documents."
  value       = var.assessment_config_container_name
}

output "assessment_reference_container_name" {
  description = "Blob container for static assessment reference assets."
  value       = var.assessment_reference_container_name
}

output "assessment_bootstrap_container_name" {
  description = "Blob container for Bootstrap manifests and onboarding exports."
  value       = var.assessment_bootstrap_container_name
}

output "assessment_jobs_table_name" {
  description = "Table name for assessment jobs."
  value       = var.assessment_jobs_table_name
}

output "assessment_clients_table_name" {
  description = "Table name for client registration metadata."
  value       = var.assessment_clients_table_name
}

output "assessment_client_subscriptions_table_name" {
  description = "Table name for client subscription bindings."
  value       = var.assessment_client_subscriptions_table_name
}

output "assessment_queue_name" {
  description = "Queue name for assessment job dispatch."
  value       = var.assessment_queue_name
}

output "key_vault_name" {
  description = "Provider-managed Key Vault name for client secret references."
  value       = azurerm_key_vault.bootstrap.name
}

output "key_vault_uri" {
  description = "Provider-managed Key Vault URI for onboarding and runtime secret resolution."
  value       = azurerm_key_vault.bootstrap.vault_uri
}

output "bootstrap_operator_identity_id" {
  description = "User-assigned identity intended for future automated Bootstrap workflows."
  value       = azurerm_user_assigned_identity.bootstrap_operator.id
}

output "assessment_runtime_identity_id" {
  description = "User-assigned identity reserved for the Functions and WebApp runtime phase."
  value       = azurerm_user_assigned_identity.assessment_runtime.id
}