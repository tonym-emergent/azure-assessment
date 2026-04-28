import {
  app,
  HttpRequest,
  HttpResponseInit,
  InvocationContext,
} from "@azure/functions";

import { jsonResponse } from "../shared/response";
import {
  getArtifactLink,
  getAssessmentJob,
  resolveArtifactBlobPath,
} from "../shared/storage";
import { AssessmentArtifactName } from "../shared/types";

const validArtifactNames: AssessmentArtifactName[] = [
  "json",
  "csv",
  "html",
  "log",
  "manifest",
];

export async function getAssessmentArtifact(
  request: HttpRequest,
  _context: InvocationContext,
): Promise<HttpResponseInit> {
  const jobId = request.params.jobId;
  const artifactName = request.params.artifactName as AssessmentArtifactName;

  if (!jobId) {
    return jsonResponse(400, { error: "Missing jobId route parameter." });
  }

  if (!validArtifactNames.includes(artifactName)) {
    return jsonResponse(400, { error: `Unsupported artifact name: ${artifactName}` });
  }

  const job = await getAssessmentJob(jobId);
  if (!job) {
    return jsonResponse(404, { error: `Assessment job not found: ${jobId}` });
  }

  const blobPath = resolveArtifactBlobPath(job, artifactName);
  if (!blobPath) {
    return jsonResponse(404, {
      error: `Artifact '${artifactName}' not available for assessment job ${jobId}`,
    });
  }

  const artifact = await getArtifactLink(artifactName, blobPath);
  return jsonResponse(200, artifact);
}

app.http("getAssessmentArtifact", {
  route: "assessments/{jobId}/artifacts/{artifactName}",
  methods: ["GET"],
  authLevel: "function",
  handler: getAssessmentArtifact,
});