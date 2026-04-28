import { execFile } from "node:child_process";
import { promisify } from "node:util";

import { getAppSettings } from "./config";
import {
  enqueueVmSkuCatalogRefresh,
  getVmSkuCatalogMetadataEntity,
  listVmSkuCatalogEntities,
  upsertVmSkuCatalogEntities,
  upsertVmSkuCatalogMetadataEntity,
} from "./storage";
import {
  VmSkuCatalogCacheRecord,
  VmSkuCatalogEntity,
  VmSkuCatalogLookupRequest,
  VmSkuCatalogMetadataEntity,
  VmSkuCatalogRefreshQueueMessage,
  VmSkuCatalogRefreshReason,
  VmSkuSpec,
} from "./types";

const execFileAsync = promisify(execFile);

interface AzureVmSkuRecord {
  name?: string;
  restrictions?: Array<{ reasonCode?: string }>;
  capabilities?: Array<{ name?: string; value?: string }>;
}

interface VmSkuCatalogKeyParts {
  key: string;
  partitionKey: string;
  metadataRowKey: string;
  familyKey: string;
  families: string[];
}

interface GetVmSkuCatalogOptions {
  enqueueRefreshOnMiss?: boolean;
}

function normalizeFamilies(families?: string[]): string[] {
  const configuredFamilies = families && families.length > 0
    ? families
    : getAppSettings().vmSkuTargetFamilies;

  const normalized = configuredFamilies
    .flatMap((family) => family.split(/[;,]/))
    .map((family) => family.trim().toUpperCase())
    .filter((family) => family.length > 0);

  return [...new Set(normalized.length > 0 ? normalized : ["B", "D", "E"])].sort();
}

function normalizeRequest(
  request: VmSkuCatalogLookupRequest,
): Required<VmSkuCatalogLookupRequest> {
  return {
    location: request.location.trim(),
    families: normalizeFamilies(request.families),
  };
}

function getCatalogKeyParts(
  request: VmSkuCatalogLookupRequest,
): VmSkuCatalogKeyParts {
  const normalized = normalizeRequest(request);
  const normalizedLocation = normalized.location.toLowerCase();
  const familyKey = normalized.families.join("-");
  const partitionKey = `vmsku:${normalizedLocation}`;

  return {
    key: `${partitionKey}|${familyKey}`,
    partitionKey,
    metadataRowKey: `meta|${familyKey}`,
    familyKey,
    families: normalized.families,
  };
}

function projectVmSkuSpec(entity: VmSkuCatalogEntity): VmSkuSpec {
  return {
    Name: entity.skuName,
    Family: entity.family,
    VCpu: entity.vCpu,
    MemoryGB: entity.memoryGB,
    MaxDataDiskCount: entity.maxDataDiskCount,
    PremiumIO: entity.premiumIO,
  };
}

function isCacheFresh(record: VmSkuCatalogCacheRecord): boolean {
  return new Date(record.expiresAt).getTime() > Date.now();
}

function getCapabilityValue(
  capabilities: AzureVmSkuRecord["capabilities"],
  name: string,
): string {
  for (const capability of capabilities || []) {
    if ((capability?.name || "") === name) {
      return capability?.value || "";
    }
  }

  return "";
}

function buildVmSkuSpecs(
  records: AzureVmSkuRecord[],
  families: string[],
): VmSkuSpec[] {
  const allowedFamilies = new Set(families);
  const items: VmSkuSpec[] = [];

  for (const sku of records) {
    const name = String(sku.name || "");
    const familyMatch = /^Standard_([A-Z])/.exec(name);
    if (!familyMatch) {
      continue;
    }

    const family = familyMatch[1].toUpperCase();
    if (!allowedFamilies.has(family)) {
      continue;
    }

    if (/Promo/i.test(name)) {
      continue;
    }

    const unavailable = (sku.restrictions || []).some((restriction) =>
      /NotAvailable/i.test(String(restriction?.reasonCode || "")),
    );
    if (unavailable) {
      continue;
    }

    let vCpuValue = getCapabilityValue(sku.capabilities, "vCPUsAvailable");
    if (!vCpuValue) {
      vCpuValue = getCapabilityValue(sku.capabilities, "vCPUs");
    }

    const memoryValue = getCapabilityValue(sku.capabilities, "MemoryGB");
    if (!vCpuValue || !memoryValue) {
      continue;
    }

    items.push({
      Name: name,
      Family: family,
      VCpu: Math.round(Number(vCpuValue)),
      MemoryGB: Number(memoryValue),
      MaxDataDiskCount: Math.round(
        Number(getCapabilityValue(sku.capabilities, "MaxDataDiskCount") || 0),
      ),
      PremiumIO: getCapabilityValue(sku.capabilities, "PremiumIO"),
    });
  }

  return items.sort(
    (left, right) =>
      left.VCpu - right.VCpu ||
      left.MemoryGB - right.MemoryGB ||
      left.Name.localeCompare(right.Name),
  );
}

function resolveAzureCliCommand(): string {
  return process.platform === "win32" ? "az.cmd" : "az";
}

async function invokeAzureVmSkuQuery(location: string): Promise<AzureVmSkuRecord[]> {
  try {
    const { stdout } = await execFileAsync(
      resolveAzureCliCommand(),
      [
        "vm",
        "list-skus",
        "--location",
        location,
        "--resource-type",
        "virtualMachines",
        "--output",
        "json",
      ],
      {
        shell: process.platform === "win32",
        maxBuffer: 20 * 1024 * 1024,
      },
    );

    return JSON.parse(stdout) as AzureVmSkuRecord[];
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Failed to query Azure VM SKU catalog for ${location}: ${message}`);
  }
}

function createSkuEntity(
  request: Required<VmSkuCatalogLookupRequest>,
  item: VmSkuSpec,
  refreshId: string,
  fetchedAt: string,
  expiresAt: string,
): VmSkuCatalogEntity {
  return {
    partitionKey: `vmsku:${request.location.toLowerCase()}`,
    rowKey: `sku|${item.Name.toLowerCase()}`,
    entityType: "sku",
    location: request.location,
    skuName: item.Name,
    family: item.Family,
    vCpu: item.VCpu,
    memoryGB: item.MemoryGB,
    maxDataDiskCount: item.MaxDataDiskCount,
    premiumIO: item.PremiumIO,
    refreshId,
    fetchedAt,
    expiresAt,
  };
}

function createMetadataEntity(
  request: Required<VmSkuCatalogLookupRequest>,
  refreshId: string,
  fetchedAt: string,
  expiresAt: string,
  itemCount: number,
  source: string,
): VmSkuCatalogMetadataEntity {
  const keyParts = getCatalogKeyParts(request);
  return {
    partitionKey: keyParts.partitionKey,
    rowKey: keyParts.metadataRowKey,
    entityType: "metadata",
    location: request.location,
    familyKey: keyParts.familyKey,
    refreshId,
    fetchedAt,
    expiresAt,
    itemCount,
    source,
  };
}

function buildCacheRecord(
  request: Required<VmSkuCatalogLookupRequest>,
  metadata: VmSkuCatalogMetadataEntity,
  items: VmSkuSpec[],
  cacheStatus: VmSkuCatalogCacheRecord["cacheStatus"],
): VmSkuCatalogCacheRecord {
  return {
    key: getCatalogKeyParts(request).key,
    request,
    items,
    cacheStatus,
    fetchedAt: metadata.fetchedAt,
    expiresAt: metadata.expiresAt,
    refreshId: metadata.refreshId,
  };
}

export async function getCachedVmSkuCatalog(
  request: VmSkuCatalogLookupRequest,
): Promise<VmSkuCatalogCacheRecord | null> {
  const normalized = normalizeRequest(request);
  const keyParts = getCatalogKeyParts(normalized);
  const metadata = await getVmSkuCatalogMetadataEntity(
    keyParts.partitionKey,
    keyParts.metadataRowKey,
  );
  if (!metadata) {
    return null;
  }

  const entities = await listVmSkuCatalogEntities(keyParts.partitionKey);
  const items = entities
    .filter(
      (entity) =>
        entity.entityType === "sku" &&
        entity.refreshId === metadata.refreshId &&
        keyParts.families.includes(entity.family),
    )
    .map(projectVmSkuSpec)
    .sort(
      (left, right) =>
        left.VCpu - right.VCpu ||
        left.MemoryGB - right.MemoryGB ||
        left.Name.localeCompare(right.Name),
    );

  return buildCacheRecord(normalized, metadata, items, "Hit");
}

export async function enqueueTargetedVmSkuCatalogRefresh(
  request: VmSkuCatalogLookupRequest,
  reason: VmSkuCatalogRefreshReason,
): Promise<void> {
  const normalized = normalizeRequest(request);
  const message: VmSkuCatalogRefreshQueueMessage = {
    ...normalized,
    reason,
    requestedAt: new Date().toISOString(),
  };

  await enqueueVmSkuCatalogRefresh(message);
}

export async function refreshVmSkuCatalog(
  request: VmSkuCatalogLookupRequest,
  reason: VmSkuCatalogRefreshReason,
): Promise<VmSkuCatalogCacheRecord> {
  const normalized = normalizeRequest(request);
  const skuResponse = await invokeAzureVmSkuQuery(normalized.location);
  const items = buildVmSkuSpecs(skuResponse, normalized.families);
  const now = new Date();
  const fetchedAt = now.toISOString();
  const expiresAt = new Date(
    now.getTime() + getAppSettings().vmSkuCacheMaxAgeMinutes * 60 * 1000,
  ).toISOString();
  const refreshId = `${now.getTime()}-${Math.random().toString(36).slice(2, 10)}`;
  const entities = items.map((item) =>
    createSkuEntity(normalized, item, refreshId, fetchedAt, expiresAt),
  );
  const metadata = createMetadataEntity(
    normalized,
    refreshId,
    fetchedAt,
    expiresAt,
    items.length,
    reason,
  );

  await upsertVmSkuCatalogEntities(entities);
  await upsertVmSkuCatalogMetadataEntity(metadata);

  return buildCacheRecord(normalized, metadata, items, "Live");
}

export async function getVmSkuCatalog(
  request: VmSkuCatalogLookupRequest,
  options: GetVmSkuCatalogOptions = {},
): Promise<VmSkuCatalogCacheRecord> {
  const normalized = normalizeRequest(request);
  const cached = await getCachedVmSkuCatalog(normalized);
  if (cached && isCacheFresh(cached)) {
    return cached;
  }

  if (!cached && options.enqueueRefreshOnMiss !== false) {
    try {
      await enqueueTargetedVmSkuCatalogRefresh(normalized, "CacheMiss");
    } catch {
      // The current request should still proceed if the background refresh could not be queued.
    }
  }

  try {
    return await refreshVmSkuCatalog(
      normalized,
      cached ? "Stale" : "CacheMiss",
    );
  } catch (error) {
    if (cached) {
      return {
        ...cached,
        cacheStatus: "Stale",
      };
    }

    throw error;
  }
}