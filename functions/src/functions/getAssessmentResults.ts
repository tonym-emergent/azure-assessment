import {
  app,
  HttpRequest,
  HttpResponseInit,
  InvocationContext,
} from "@azure/functions";

import { jsonResponse } from "../shared/response";
import {
  getAssessmentJob,
  getAssessmentManifest,
  getJobArtifactLinks,
} from "../shared/storage";
import { AssessmentResultsResponse } from "../shared/types";

export async function getAssessmentResults(
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

  const [manifest, artifacts] = await Promise.all([
    getAssessmentManifest(job),
    getJobArtifactLinks(job),
  ]);

  const response: AssessmentResultsResponse = {
    job,
    manifest,
    artifacts,
  };

  return jsonResponse(200, response);
}

app.http("getAssessmentResults", {
  route: "assessments/{jobId}/results",
  methods: ["GET"],
  authLevel: "function",
  handler: getAssessmentResults,
});