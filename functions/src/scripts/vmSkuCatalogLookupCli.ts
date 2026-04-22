import { getVmSkuCatalog } from "../shared/vmSkuCatalog";
import { VmSkuCatalogLookupRequest } from "../shared/types";

function getArgumentValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  if (index === -1 || index + 1 >= process.argv.length) {
    return undefined;
  }

  return process.argv[index + 1];
}

function parseRequest(): VmSkuCatalogLookupRequest {
  const location = getArgumentValue("--location");
  const families = getArgumentValue("--families");
  if (!location) {
    throw new Error("Missing required argument: --location.");
  }

  return {
    location,
    families: families
      ? families
          .split(/[;,]/)
          .map((family) => family.trim())
          .filter((family) => family.length > 0)
      : undefined,
  };
}

async function main(): Promise<void> {
  const request = parseRequest();
  const result = await getVmSkuCatalog(request, {
    enqueueRefreshOnMiss: true,
  });

  process.stdout.write(JSON.stringify(result.items));
}

void main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
});