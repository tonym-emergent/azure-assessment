import { app, InvocationContext, Timer } from "@azure/functions";

import { getAppSettings } from "../shared/config";
import { enqueueTargetedVmSkuCatalogRefresh } from "../shared/vmSkuCatalog";

export async function scheduleVmSkuCatalogRefresh(
  _timer: Timer,
  context: InvocationContext,
): Promise<void> {
  const settings = getAppSettings();
  if (settings.vmSkuTargetRegions.length === 0) {
    context.log("Skipping VM SKU catalog refresh because no target regions are configured.");
    return;
  }

  for (const location of settings.vmSkuTargetRegions) {
    await enqueueTargetedVmSkuCatalogRefresh(
      {
        location,
        families: settings.vmSkuTargetFamilies,
      },
      "Scheduled",
    );
  }

  context.log(
    `Queued VM SKU catalog refresh for ${settings.vmSkuTargetRegions.length} region(s).`,
  );
}

app.timer("scheduleVmSkuCatalogRefresh", {
  schedule: getAppSettings().vmSkuRefreshSchedule,
  handler: scheduleVmSkuCatalogRefresh,
});