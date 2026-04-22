import {
  app,
  HttpRequest,
  HttpResponseInit,
  InvocationContext,
} from "@azure/functions";

import { jsonResponse } from "../shared/response";
import { listAssessmentJobs } from "../shared/storage";

export async function listAssessments(
  request: HttpRequest,
  _context: InvocationContext,
): Promise<HttpResponseInit> {
  const limitValue = Number(request.query.get("limit") || 25);
  const limit = Number.isFinite(limitValue) && limitValue > 0 ? limitValue : 25;
  const clientId = request.query.get("clientId")?.trim() || undefined;
  const jobs = await listAssessmentJobs(Math.min(limit, 100), clientId);
  return jsonResponse(200, {
    value: jobs,
    clientId: clientId || null,
  });
}

app.http("listAssessments", {
  route: "assessments",
  methods: ["GET"],
  authLevel: "function",
  handler: listAssessments,
});