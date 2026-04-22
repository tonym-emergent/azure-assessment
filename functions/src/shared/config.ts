import path from "node:path";

export interface AppSettings {
  storageConnectionString: string;
  queueName: string;
  resultsContainer: string;
  configContainer: string;
  referenceContainer: string;
  tableName: string;
  scriptPath: string;
  defaultConfigPath: string;
  defaultOutputPrefix: string;
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

export function getAppSettings(): AppSettings {
  const basePath = process.cwd();

  return {
    storageConnectionString: requireSetting("AzureWebJobsStorage"),
    queueName: getQueueName(),
    resultsContainer:
      process.env.ASSESSMENT_RESULTS_CONTAINER?.trim() || "assessment-results",
    configContainer:
      process.env.ASSESSMENT_CONFIG_CONTAINER?.trim() || "assessment-config",
    referenceContainer:
      process.env.ASSESSMENT_REFERENCE_CONTAINER?.trim() || "assessment-reference",
    tableName: process.env.ASSESSMENT_TABLE_NAME?.trim() || "assessmentjobs",
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
  };
}