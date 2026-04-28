data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  lower   = true
  numeric = true
  special = false
}

locals {
  normalized_environment_name = replace(lower(var.environment_name), "/[^a-z0-9]/", "")
  short_environment_name      = substr(local.normalized_environment_name, 0, 8)
  unique_suffix               = random_string.suffix.result

  resource_group_name = coalesce(
    var.resource_group_name,
    "rg-${var.environment_name}-assessment-bootstrap",
  )

  storage_account_name = coalesce(
    var.storage_account_name,
    substr("st${local.short_environment_name}${local.unique_suffix}", 0, 24),
  )

  key_vault_name = coalesce(
    var.key_vault_name,
    substr("kv-${local.short_environment_name}-${local.unique_suffix}", 0, 24),
  )

  application_insights_name = coalesce(
    var.application_insights_name,
    "appi-${var.environment_name}-${local.unique_suffix}",
  )

  log_analytics_workspace_name = coalesce(
    var.log_analytics_workspace_name,
    "log-${var.environment_name}-${local.unique_suffix}",
  )

  common_tags = merge(var.tags, {
    Environment = var.environment_name
    Phase       = "Bootstrap"
    Workload    = "azure-assessment"
  })
}

resource "azurerm_resource_group" "bootstrap" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_log_analytics_workspace" "bootstrap" {
  name                = local.log_analytics_workspace_name
  location            = azurerm_resource_group.bootstrap.location
  resource_group_name = azurerm_resource_group.bootstrap.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.common_tags
}

resource "azurerm_application_insights" "bootstrap" {
  name                = local.application_insights_name
  location            = azurerm_resource_group.bootstrap.location
  resource_group_name = azurerm_resource_group.bootstrap.name
  workspace_id        = azurerm_log_analytics_workspace.bootstrap.id
  application_type    = "web"
  tags                = local.common_tags
}

resource "azurerm_storage_account" "bootstrap" {
  name                          = local.storage_account_name
  resource_group_name           = azurerm_resource_group.bootstrap.name
  location                      = azurerm_resource_group.bootstrap.location
  account_tier                  = "Standard"
  account_replication_type      = var.storage_account_replication_type
  min_tls_version               = "TLS1_2"
  https_traffic_only_enabled    = true
  shared_access_key_enabled     = true
  allow_nested_items_to_be_public = false
  tags                          = local.common_tags

  blob_properties {
    versioning_enabled       = true
    last_access_time_enabled = true

    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }
}

resource "azurerm_storage_container" "bootstrap" {
  for_each = toset([
    var.assessment_results_container_name,
    var.assessment_config_container_name,
    var.assessment_reference_container_name,
    var.assessment_bootstrap_container_name,
  ])

  name                  = each.value
  storage_account_id    = azurerm_storage_account.bootstrap.id
  container_access_type = "private"
}

resource "azurerm_storage_queue" "bootstrap" {
  for_each = toset([var.assessment_queue_name])

  name               = each.value
  storage_account_id = azurerm_storage_account.bootstrap.id
}

resource "azurerm_storage_table" "bootstrap" {
  for_each = toset([
    var.assessment_jobs_table_name,
    var.assessment_clients_table_name,
    var.assessment_client_subscriptions_table_name,
  ])

  name                 = each.value
  storage_account_name = azurerm_storage_account.bootstrap.name
}

resource "azurerm_key_vault" "bootstrap" {
  name                          = local.key_vault_name
  location                      = azurerm_resource_group.bootstrap.location
  resource_group_name           = azurerm_resource_group.bootstrap.name
  tenant_id                     = var.provider_tenant_id
  sku_name                      = var.key_vault_sku_name
  rbac_authorization_enabled    = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 90
  public_network_access_enabled = true
  tags                          = local.common_tags
}

resource "azurerm_user_assigned_identity" "bootstrap_operator" {
  name                = "id-${var.environment_name}-bootstrap-operator"
  location            = azurerm_resource_group.bootstrap.location
  resource_group_name = azurerm_resource_group.bootstrap.name
  tags                = local.common_tags
}

resource "azurerm_user_assigned_identity" "assessment_runtime" {
  name                = "id-${var.environment_name}-assessment-runtime"
  location            = azurerm_resource_group.bootstrap.location
  resource_group_name = azurerm_resource_group.bootstrap.name
  tags                = local.common_tags
}

resource "azurerm_role_assignment" "bootstrap_operator_storage_blob" {
  scope                = azurerm_storage_account.bootstrap.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_user_assigned_identity.bootstrap_operator.principal_id
}

resource "azurerm_role_assignment" "bootstrap_operator_storage_queue" {
  scope                = azurerm_storage_account.bootstrap.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_user_assigned_identity.bootstrap_operator.principal_id
}

resource "azurerm_role_assignment" "bootstrap_operator_storage_table" {
  scope                = azurerm_storage_account.bootstrap.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_user_assigned_identity.bootstrap_operator.principal_id
}

resource "azurerm_role_assignment" "bootstrap_operator_key_vault" {
  scope                = azurerm_key_vault.bootstrap.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_user_assigned_identity.bootstrap_operator.principal_id
}

resource "azurerm_role_assignment" "assessment_runtime_storage_blob" {
  scope                = azurerm_storage_account.bootstrap.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_user_assigned_identity.assessment_runtime.principal_id
}

resource "azurerm_role_assignment" "assessment_runtime_storage_queue" {
  scope                = azurerm_storage_account.bootstrap.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_user_assigned_identity.assessment_runtime.principal_id
}

resource "azurerm_role_assignment" "assessment_runtime_storage_table" {
  scope                = azurerm_storage_account.bootstrap.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_user_assigned_identity.assessment_runtime.principal_id
}

resource "azurerm_role_assignment" "assessment_runtime_key_vault" {
  scope                = azurerm_key_vault.bootstrap.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.assessment_runtime.principal_id
}