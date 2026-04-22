import {
  app,
  HttpRequest,
  HttpResponseInit,
  InvocationContext,
  output,
  StorageQueueOutput,
} from "@azure/functions";

import { getRuntimeAzureContext } from "../shared/azureContext";
import { getQueueName } from "../shared/config";
import { jsonResponse } from "../shared/response";
import { createAssessmentJob } from "../shared/storage";
import { AssessmentQueueMessage, AssessmentRequest } from "../shared/types";

const assessmentQueueOutput: StorageQueueOutput = output.storageQueue({
  queueName: getQueueName(),
  connection: "AzureWebJobsStorage",
});

function generateJobId(): string {
  return `job-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
}

function normalizeStringList(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) {
    return undefined;
  }

  const items = value
    .map((entry) => String(entry).trim())
    .filter((entry) => entry.length > 0);
  return items.length > 0 ? items : undefined;
}

function normalizeOptionalString(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }

  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function validateRequest(payload: unknown): AssessmentRequest {
  if (!payload || typeof payload !== "object") {
    throw new Error("Request body must be a JSON object.");
  }

  const candidate = payload as Record<string, unknown>;
  const tool = candidate.tool;
  if (tool !== "vm") {
    throw new Error("Only the 'vm' assessment tool is currently supported.");
  }

  const daysToInspect =
    candidate.daysToInspect === undefined
      ? 14
      : Number(candidate.daysToInspect);
  if (!Number.isFinite(daysToInspect) || daysToInspect <= 0) {
    throw new Error("daysToInspect must be a positive number.");
  }

  const runtimeContext = getRuntimeAzureContext();
  const subscriptionIds =
    normalizeStringList(candidate.subscriptionIds) ||
    runtimeContext.defaultSubscriptionIds;

  return {
    tool,
    clientId:
      normalizeOptionalString(candidate.clientId) ||
      runtimeContext.defaultClientId,
    assessmentProfileId: normalizeOptionalString(candidate.assessmentProfileId),
    targetTenantId:
      normalizeOptionalString(candidate.targetTenantId) ||
      runtimeContext.providerTenantId,
    subscriptionIds,
    vmNames: normalizeStringList(candidate.vmNames),
    daysToInspect,
    configBlobPath: normalizeOptionalString(candidate.configBlobPath),
    refreshAdvisor:
      candidate.refreshAdvisor === undefined
        ? false
        : Boolean(candidate.refreshAdvisor),
    outputPrefix: normalizeOptionalString(candidate.outputPrefix),
    requestedBy: normalizeOptionalString(candidate.requestedBy),
  };
}

export async function submitAssessment(
  request: HttpRequest,
  context: InvocationContext,
): Promise<HttpResponseInit> {
  try {
    const payload = await request.json();
    const assessmentRequest = validateRequest(payload);
    const jobId = generateJobId();
    const job = await createAssessmentJob(jobId, assessmentRequest);
    const queueMessage: AssessmentQueueMessage = {
      jobId,
      clientId: job.clientId,
    };
    context.extraOutputs.set(assessmentQueueOutput, [queueMessage]);

    return jsonResponse(202, {
      jobId,
      clientId: job.clientId,
      status: job.status,
      requestedAt: job.requestedAt,
      targetTenantId: job.request.targetTenantId,
      subscriptionIds: job.request.subscriptionIds || [],
      message: job.message,
    });
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : "Invalid request.";
    return jsonResponse(400, { error: message });
  }
}

app.http("submitAssessment", {
  route: "assessments",
  methods: ["POST"],
  authLevel: "function",
  extraOutputs: [assessmentQueueOutput],
  handler: submitAssessment,
});