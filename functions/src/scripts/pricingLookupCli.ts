import { getPricingModel } from "../shared/pricing";
import { PricingLookupRequest } from "../shared/types";

function getArgumentValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  if (index === -1 || index + 1 >= process.argv.length) {
    return undefined;
  }

  return process.argv[index + 1];
}

function parseRequest(): PricingLookupRequest {
  const armRegionName = getArgumentValue("--arm-region-name");
  const armSkuName = getArgumentValue("--arm-sku-name");
  const osType = getArgumentValue("--os-type");
  const licenseType = getArgumentValue("--license-type") || "";

  if (!armRegionName || !armSkuName || !osType) {
    throw new Error(
      "Missing required arguments: --arm-region-name, --arm-sku-name, and --os-type.",
    );
  }

  return {
    armRegionName,
    armSkuName,
    osType,
    licenseType,
  };
}

async function main(): Promise<void> {
  const request = parseRequest();
  const result = await getPricingModel(request, {
    enqueueRefreshOnMiss: true,
  });

  process.stdout.write(JSON.stringify(result.model));
}

void main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
});