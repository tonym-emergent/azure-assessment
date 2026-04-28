import { app, InvocationContext } from "@azure/functions";

import { getQueueName } from "../shared/config";
import { runAssessmentJob } from "../shared/assessmentRunner";
import {
  getAssessmentJob,
  updateAssessmentStatus,
} from "../shared/storage";
import { AssessmentQueueMessage } from "../shared/types";

export async function runAssessmentQueueJob(
  message: unknown,
  context: InvocationContext,
): Promise<void> {
  const payload = message as AssessmentQueueMessage;
  if (!payload?.jobId) {
    throw new Error("Queue message did not include a jobId.");
  }

  const job = await getAssessmentJob(payload.jobId);
  if (!job) {
    throw new Error(`Assessment job not found: ${payload.jobId}`);
  }

  await updateAssessmentStatus(job.jobId, "Running", "Assessment is running");

  try {
    await runAssessmentJob(job.jobId, job.request, context);
  } catch (error: unknown) {
    const messageText = error instanceof Error ? error.message : String(error);
    await updateAssessmentStatus(job.jobId, "Failed", messageText);
    throw error;
  }
}

app.storageQueue("runAssessmentJob", {
  queueName: getQueueName(),
  connection: "AzureWebJobsStorage",
  handler: runAssessmentQueueJob,
});