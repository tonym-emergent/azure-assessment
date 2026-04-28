import { app, InvocationContext } from "@azure/functions";

import { getPricingRefreshQueueName } from "../shared/config";
import { refreshPricingModel } from "../shared/pricing";
import { PricingRefreshQueueMessage } from "../shared/types";

function parseMessage(message: unknown): PricingRefreshQueueMessage {
  if (typeof message === "string") {
    return JSON.parse(message) as PricingRefreshQueueMessage;
  }

  return message as PricingRefreshQueueMessage;
}

export async function refreshPricingCacheQueueJob(
  message: unknown,
  context: InvocationContext,
): Promise<void> {
  const payload = parseMessage(message);
  if (!payload?.armRegionName || !payload?.armSkuName || !payload?.osType) {
    throw new Error("Pricing refresh queue message is missing region, SKU, or OS type.");
  }

  context.log(
    `Refreshing pricing cache for ${payload.armRegionName}/${payload.armSkuName}/${payload.osType}`,
  );

  await refreshPricingModel(payload, payload.reason || "Manual");
}

app.storageQueue("refreshPricingCache", {
  queueName: getPricingRefreshQueueName(),
  connection: "AzureWebJobsStorage",
  handler: refreshPricingCacheQueueJob,
});