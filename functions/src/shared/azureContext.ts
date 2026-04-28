import { getAppSettings } from "./config";
import { DEFAULT_CLIENT_ID } from "./types";

export interface RuntimeAzureContext {
  tenantId?: string;
  providerTenantId?: string;
  location?: string;
  defaultClientId: string;
  defaultSubscriptionIds: string[];
  storageSubscriptionId?: string;
  storageResourceGroup?: string;
  storageAccountName?: string;
  queueName: string;
  tableName: string;
  resultsContainer: string;
  configContainer: string;
  referenceContainer: string;
}

function parseCsvList(value?: string): string[] {
  if (!value) {
    return [];
  }

  return value
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
}

export function getRuntimeAzureContext(): RuntimeAzureContext {
  const settings = getAppSettings();
  const providerTenantId =
    process.env.ASSESSMENT_PROVIDER_TENANT_ID?.trim() ||
    process.env.ASSESSMENT_TENANT_ID?.trim() ||
    undefined;

  return {
    tenantId: providerTenantId,
    providerTenantId,
    location: process.env.ASSESSMENT_LOCATION?.trim() || undefined,
    defaultClientId:
      process.env.ASSESSMENT_DEFAULT_CLIENT_ID?.trim() || DEFAULT_CLIENT_ID,
    defaultSubscriptionIds: parseCsvList(
      process.env.ASSESSMENT_DEFAULT_SUBSCRIPTION_IDS,
    ),
    storageSubscriptionId:
      process.env.ASSESSMENT_STORAGE_SUBSCRIPTION_ID?.trim() || undefined,
    storageResourceGroup:
      process.env.ASSESSMENT_STORAGE_RESOURCE_GROUP?.trim() || undefined,
    storageAccountName:
      process.env.ASSESSMENT_STORAGE_ACCOUNT_NAME?.trim() || undefined,
    queueName: settings.queueName,
    tableName: settings.tableName,
    resultsContainer: settings.resultsContainer,
    configContainer: settings.configContainer,
    referenceContainer: settings.referenceContainer,
  };
}