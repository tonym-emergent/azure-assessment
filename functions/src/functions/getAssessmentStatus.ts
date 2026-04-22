import {
  app,
  HttpRequest,
  HttpResponseInit,
  InvocationContext,
} from "@azure/functions";

import { jsonResponse } from "../shared/response";
import { getAssessmentJob, getAssessmentManifest } from "../shared/storage";

export async function getAssessmentStatus(
  request: HttpRequest,
  _context: InvocationContext,
): Promise<HttpResponseInit> {
  const jobId = request.params.jobId;
  if (!jobId) {
    return jsonResponse(400, { error: "Missing jobId route parameter." });
  }

  const job = await getAssessmentJob(jobId);
  if (!job) {
    return jsonResponse(404, { error: `Assessment job not found: ${jobId}` });
  }

  const manifest = await getAssessmentManifest(job);
  return jsonResponse(200, {
    ...job,
    manifest,
  });
}

app.http("getAssessmentStatus", {
  route: "assessments/{jobId}",
  methods: ["GET"],
  authLevel: "function",
  handler: getAssessmentStatus,
});