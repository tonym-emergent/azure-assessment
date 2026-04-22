import path from "node:path";

export interface AppSettings {
  storageConnectionString: string;
  queueName: string;
  pricingRefreshQueueName: string;
  vmSkuRefreshQueueName: string;
  resultsContainer: string;
  configContainer: string;
  referenceContainer: string;
  tableName: string;
  pricingTableName: string;
  vmSkuTableName: string;
  scriptPath: string;
  defaultConfigPath: string;
  defaultOutputPrefix: string;
  pricingCacheMaxAgeMinutes: number;
  pricingLookupHelperPath: string;
  vmSkuCacheMaxAgeMinutes: number;
  vmSkuLookupHelperPath: string;
  vmSkuRefreshSchedule: string;
  vmSkuTargetRegions: string[];
  vmSkuTargetFamilies: string[];
}

function requireSetting(name: string): string {
  const value = process.env[name];
  if (!value || !value.trim()) {
    throw new Error(`Missing required app setting: ${name}`);
  }

  return value.trim();
}

export function getQueueName(): string {
  return process.env.ASSESSMENT_QUEUE_NAME?.trim() || "assessment-jobs";
}

export function getPricingRefreshQueueName(): string {
  return (
    process.env.ASSESSMENT_PRICING_REFRESH_QUEUE_NAME?.trim() ||
    "pricing-refresh-jobs"
  );
}

export function getVmSkuRefreshQueueName(): string {
  return (
    process.env.ASSESSMENT_VM_SKU_REFRESH_QUEUE_NAME?.trim() ||
    "vm-sku-refresh-jobs"
  );
}

function parseListSetting(value: string | undefined, fallback: string[] = []): string[] {
  const source = value?.trim();
  if (!source) {
    return [...fallback];
  }

  return [...new Set(
    source
      .split(/[;,]/)
      .map((item) => item.trim())
      .filter((item) => item.length > 0),
  )];
}

export function getAppSettings(): AppSettings {
  const basePath = process.cwd();
  const pricingCacheMaxAgeMinutes = Number.parseInt(
    process.env.ASSESSMENT_PRICING_CACHE_MAX_AGE_MINUTES?.trim() || "1440",
    10,
  );
  const vmSkuCacheMaxAgeMinutes = Number.parseInt(
    process.env.ASSESSMENT_VM_SKU_CACHE_MAX_AGE_MINUTES?.trim() || "1440",
    10,
  );

  return {
    storageConnectionString: requireSetting("AzureWebJobsStorage"),
    queueName: getQueueName(),
    pricingRefreshQueueName: getPricingRefreshQueueName(),
    vmSkuRefreshQueueName: getVmSkuRefreshQueueName(),
    resultsContainer:
      process.env.ASSESSMENT_RESULTS_CONTAINER?.trim() || "assessment-results",
    configContainer:
      process.env.ASSESSMENT_CONFIG_CONTAINER?.trim() || "assessment-config",
    referenceContainer:
      process.env.ASSESSMENT_REFERENCE_CONTAINER?.trim() || "assessment-reference",
    tableName: process.env.ASSESSMENT_TABLE_NAME?.trim() || "assessmentjobs",
    pricingTableName:
      process.env.ASSESSMENT_PRICING_TABLE_NAME?.trim() || "pricingcache",
    vmSkuTableName:
      process.env.ASSESSMENT_VM_SKU_TABLE_NAME?.trim() || "vmskucatalog",
    scriptPath: path.resolve(
      basePath,
      process.env.ASSESSMENT_SCRIPT_PATH?.trim() || "..\\azure-vm-analysis\\azure-vm-assessment.ps1",
    ),
    defaultConfigPath: path.resolve(
      basePath,
      process.env.ASSESSMENT_DEFAULT_CONFIG_PATH?.trim() ||
        "..\\azure-vm-analysis\\azure-vm-assessment.config.jsonc",
    ),
    defaultOutputPrefix:
      process.env.ASSESSMENT_OUTPUT_PREFIX?.trim() || "vm-analysis-api",
    pricingCacheMaxAgeMinutes:
      Number.isFinite(pricingCacheMaxAgeMinutes) && pricingCacheMaxAgeMinutes > 0
        ? pricingCacheMaxAgeMinutes
        : 1440,
    pricingLookupHelperPath: path.resolve(
      basePath,
      process.env.ASSESSMENT_PRICING_LOOKUP_HELPER_PATH?.trim() ||
        "dist\\src\\scripts\\pricingLookupCli.js",
    ),
    vmSkuCacheMaxAgeMinutes:
      Number.isFinite(vmSkuCacheMaxAgeMinutes) && vmSkuCacheMaxAgeMinutes > 0
        ? vmSkuCacheMaxAgeMinutes
        : 1440,
    vmSkuLookupHelperPath: path.resolve(
      basePath,
      process.env.ASSESSMENT_VM_SKU_LOOKUP_HELPER_PATH?.trim() ||
        "dist\\src\\scripts\\vmSkuCatalogLookupCli.js",
    ),
    vmSkuRefreshSchedule:
      process.env.ASSESSMENT_VM_SKU_REFRESH_SCHEDULE?.trim() || "0 0 */12 * * *",
    vmSkuTargetRegions: parseListSetting(
      process.env.ASSESSMENT_VM_SKU_TARGET_REGIONS,
    ),
    vmSkuTargetFamilies: parseListSetting(
      process.env.ASSESSMENT_VM_SKU_TARGET_FAMILIES,
      ["B", "D", "E"],
    ),
  };
}