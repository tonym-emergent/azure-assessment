import { execFile } from "node:child_process";
import { existsSync, promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

import { InvocationContext } from "@azure/functions";

import { getAppSettings } from "./config";
import { DEFAULT_CLIENT_ID, AssessmentManifest, AssessmentRequest } from "./types";
import {
  downloadConfigBlob,
  updateAssessmentJob,
  uploadLocalFileToResults,
  uploadTextToResults,
} from "./storage";

const execFileAsync = promisify(execFile);

interface ParsedArtifacts {
  jsonPath?: string;
  csvPath?: string;
  htmlPath?: string;
}

function normalizeList(values?: string[]): string[] {
  if (!values) {
    return [];
  }

  return values.map((value) => value.trim()).filter((value) => value.length > 0);
}

function parseArtifactPaths(output: string): ParsedArtifacts {
  const artifacts: ParsedArtifacts = {};
  const jsonMatch = output.match(/^\s*JSON:\s+(.+)$/m);
  const csvMatch = output.match(/^\s*CSV:\s+(.+)$/m);
  const htmlMatch = output.match(/^\s*HTML:\s+(.+)$/m);

  if (jsonMatch?.[1]) {
    artifacts.jsonPath = jsonMatch[1].trim();
  }

  if (csvMatch?.[1]) {
    artifacts.csvPath = csvMatch[1].trim();
  }

  if (htmlMatch?.[1]) {
    artifacts.htmlPath = htmlMatch[1].trim();
  }

  return artifacts;
}

function resolvePowerShellExecutable(): string {
  const configuredPath = process.env.ASSESSMENT_PWSH_PATH?.trim();
  if (configuredPath) {
    return configuredPath;
  }

  if (process.platform === "win32") {
    const candidates = [
      process.env.ProgramW6432,
      process.env.ProgramFiles,
      process.env["ProgramFiles(x86)"],
    ]
      .filter((value): value is string => Boolean(value && value.trim()))
      .map((basePath) => path.join(basePath, "PowerShell", "7", "pwsh.exe"));

    const discoveredPath = candidates.find((candidate) => existsSync(candidate));
    if (discoveredPath) {
      return discoveredPath;
    }
  }

  return "pwsh";
}

async function filterExistingArtifacts(
  artifacts: ParsedArtifacts,
): Promise<ParsedArtifacts> {
  const entries = await Promise.all(
    Object.entries(artifacts).map(async ([key, candidatePath]) => {
      if (!candidatePath) {
        return [key, undefined] as const;
      }

      try {
        await fs.access(candidatePath);
        return [key, candidatePath] as const;
      } catch {
        return [key, undefined] as const;
      }
    }),
  );

  return Object.fromEntries(entries) as ParsedArtifacts;
}

async function resolveConfigPath(
  request: AssessmentRequest,
  workingDirectory: string,
): Promise<string | undefined> {
  if (request.configBlobPath) {
    const configContent = await downloadConfigBlob(request.configBlobPath);
    const configPath = path.join(workingDirectory, "assessment.config.jsonc");
    await fs.writeFile(configPath, configContent);
    return configPath;
  }

  const settings = getAppSettings();
  try {
    await fs.access(settings.defaultConfigPath);
    return settings.defaultConfigPath;
  } catch {
    return undefined;
  }
}

export async function runAssessmentJob(
  jobId: string,
  request: AssessmentRequest,
  context: InvocationContext,
): Promise<AssessmentManifest> {
  if (request.tool !== "vm") {
    throw new Error(`Unsupported assessment tool: ${request.tool}`);
  }

  const settings = getAppSettings();
  const workingDirectory = await fs.mkdtemp(
    path.join(os.tmpdir(), `assessment-${jobId}-`),
  );

  try {
    const configPath = await resolveConfigPath(request, workingDirectory);
    const outputPrefix = `${request.outputPrefix || settings.defaultOutputPrefix}-${jobId}`;
    const clientId = request.clientId?.trim() || DEFAULT_CLIENT_ID;
    const argumentsList = [
      "-NoLogo",
      "-NoProfile",
      "-File",
      settings.scriptPath,
      "-DaysToInspect",
      String(request.daysToInspect || 14),
      "-OutputPrefix",
      outputPrefix,
    ];

    if (configPath) {
      argumentsList.push("-ConfigPath", configPath);
    }

    const vmNames = normalizeList(request.vmNames);
    if (vmNames.length > 0) {
      argumentsList.push("-VMName", vmNames.join(","));
    }

    const subscriptionIds = normalizeList(request.subscriptionIds);
    if (subscriptionIds.length > 0) {
      argumentsList.push("-SubscriptionId", ...subscriptionIds);
    }

    if (request.refreshAdvisor) {
      argumentsList.push("-RefreshAdvisor");
    }

    context.log(`Executing PowerShell assessment for job ${jobId}`);
    const execution = await execFileAsync(resolvePowerShellExecutable(), argumentsList, {
      cwd: path.dirname(settings.scriptPath),
      env: {
        ...process.env,
        ASSESSMENT_PRICING_LOOKUP_HELPER_PATH: settings.pricingLookupHelperPath,
        ASSESSMENT_VM_SKU_LOOKUP_HELPER_PATH: settings.vmSkuLookupHelperPath,
        ASSESSMENT_VM_SKU_TARGET_FAMILIES: settings.vmSkuTargetFamilies.join(","),
      },
      maxBuffer: 10 * 1024 * 1024,
    });
    const combinedOutput = [execution.stdout, execution.stderr]
      .filter(Boolean)
      .join("\n");
    const artifacts = await filterExistingArtifacts(parseArtifactPaths(combinedOutput));

    if (!artifacts.jsonPath && !artifacts.csvPath && !artifacts.htmlPath) {
      throw new Error(
        "Assessment completed without discoverable output artifacts in stdout.",
      );
    }

    const blobPrefix = `${request.tool}/${clientId}/${jobId}`;
    const jsonBlobPath = artifacts.jsonPath
      ? await uploadLocalFileToResults(
          artifacts.jsonPath,
          `${blobPrefix}/${path.basename(artifacts.jsonPath)}`,
        )
      : undefined;
    const csvBlobPath = artifacts.csvPath
      ? await uploadLocalFileToResults(
          artifacts.csvPath,
          `${blobPrefix}/${path.basename(artifacts.csvPath)}`,
        )
      : undefined;
    const htmlBlobPath = artifacts.htmlPath
      ? await uploadLocalFileToResults(
          artifacts.htmlPath,
          `${blobPrefix}/${path.basename(artifacts.htmlPath)}`,
        )
      : undefined;
    const logBlobPath = await uploadTextToResults(
      `${blobPrefix}/execution.log`,
      combinedOutput,
      "text/plain; charset=utf-8",
    );

    const manifest: AssessmentManifest = {
      jobId,
      clientId,
      tool: request.tool,
      status: "Completed",
      createdAt: new Date().toISOString(),
      artifacts: {
        jsonBlobPath,
        csvBlobPath,
        htmlBlobPath,
        logBlobPath,
      },
    };

    const manifestBlobPath = await uploadTextToResults(
      `${blobPrefix}/manifest.json`,
      JSON.stringify(manifest, null, 2),
      "application/json; charset=utf-8",
    );
    manifest.artifacts.manifestBlobPath = manifestBlobPath;

    await updateAssessmentJob(jobId, {
      status: "Completed",
      message: "Assessment completed successfully",
      jsonBlobPath,
      csvBlobPath,
      htmlBlobPath,
      logBlobPath,
      manifestBlobPath,
    });

    return manifest;
  } finally {
    await fs.rm(workingDirectory, { recursive: true, force: true });
  }
}