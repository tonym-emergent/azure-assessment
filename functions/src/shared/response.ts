import { HttpResponseInit } from "@azure/functions";

export function jsonResponse(status: number, body: unknown): HttpResponseInit {
  return {
    status,
    jsonBody: body,
    headers: {
      "content-type": "application/json",
    },
  };
}

export function noContentResponse(): HttpResponseInit {
  return {
    status: 204,
  };
}