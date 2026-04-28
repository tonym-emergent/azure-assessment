import { app, InvocationContext } from "@azure/functions";

import { getVmSkuRefreshQueueName } from "../shared/config";
import { refreshVmSkuCatalog } from "../shared/vmSkuCatalog";
import { VmSkuCatalogRefreshQueueMessage } from "../shared/types";

function parseMessage(message: unknown): VmSkuCatalogRefreshQueueMessage {
  if (typeof message === "string") {
    return JSON.parse(message) as VmSkuCatalogRefreshQueueMessage;
  }

  return message as VmSkuCatalogRefreshQueueMessage;
}

export async function refreshVmSkuCatalogQueueJob(
  message: unknown,
  context: InvocationContext,
): Promise<void> {
  const payload = parseMessage(message);
  if (!payload?.location) {
    throw new Error("VM SKU refresh queue message is missing the target location.");
  }

  context.log(
    `Refreshing VM SKU catalog for ${payload.location} (${(payload.families || []).join(",") || "default families"})`,
  );

  await refreshVmSkuCatalog(payload, payload.reason || "Manual");
}

app.storageQueue("refreshVmSkuCatalog", {
  queueName: getVmSkuRefreshQueueName(),
  connection: "AzureWebJobsStorage",
  handler: refreshVmSkuCatalogQueueJob,
});