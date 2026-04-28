import {
  app,
  HttpRequest,
  HttpResponseInit,
  InvocationContext,
} from "@azure/functions";

import { getRuntimeAzureContext } from "../shared/azureContext";
import { jsonResponse } from "../shared/response";

export async function getRuntimeContext(
  _request: HttpRequest,
  _context: InvocationContext,
): Promise<HttpResponseInit> {
  return jsonResponse(200, getRuntimeAzureContext());
}

app.http("getRuntimeContext", {
  route: "context",
  methods: ["GET"],
  authLevel: "function",
  handler: getRuntimeContext,
});