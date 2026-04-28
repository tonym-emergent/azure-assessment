import { TableClient } from "@azure/data-tables";
import {
  BlobSASPermissions,
  BlobServiceClient,
  StorageSharedKeyCredential,
  generateBlobSASQueryParameters,
} from "@azure/storage-blob";
import { QueueServiceClient } from "@azure/storage-queue";

import { getAppSettings } from "./config";
import {
  AssessmentArtifactLink,
  AssessmentArtifactName,
  AssessmentArtifacts,
  DEFAULT_CLIENT_ID,
  AssessmentJobEntity,
  AssessmentJobRecord,
  AssessmentJobStatus,
  AssessmentManifest,
  AssessmentRequest,
  PricingCacheEntity,
  PricingRefreshQueueMessage,
  VmSkuCatalogEntity,
  VmSkuCatalogMetadataEntity,
  VmSkuCatalogRefreshQueueMessage,
} from "./types";

const DEVELOPMENT_STORAGE_CONNECTION_PREFIX = "UseDevelopmentStorage=true";
const DEVELOPMENT_STORAGE_ACCOUNT_NAME = "devstoreaccount1";
const DEVELOPMENT_STORAGE_ACCOUNT_KEY =
  "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==";

function escapeODataString(value: string): string {
  return value.replace(/'/g, "''");
}

function normalizeClientId(value?: string): string {
  const normalized = (value || DEFAULT_CLIENT_ID)
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");

  return normalized || DEFAULT_CLIENT_ID;
}

function getJobPartitionKey(clientId?: string): string {
  return `client:${normalizeClientId(clientId)}`;
}

function getTableClient(): TableClient {
  const settings = getAppSettings();
  return TableClient.fromConnectionString(
    settings.storageConnectionString,
    settings.tableName,
  );
}

function getBlobServiceClient(): BlobServiceClient {
  const settings = getAppSettings();
  return BlobServiceClient.fromConnectionString(settings.storageConnectionString);
}

function getQueueServiceClient(): QueueServiceClient {
  const settings = getAppSettings();
  return QueueServiceClient.fromConnectionString(settings.storageConnectionString);
}

function getResultsContainerClient() {
  const settings = getAppSettings();
  return getBlobServiceClient().getContainerClient(settings.resultsContainer);
}

function getPricingTableClient(): TableClient {
  const settings = getAppSettings();
  return TableClient.fromConnectionString(
    settings.storageConnectionString,
    settings.pricingTableName,
  );
}

function getVmSkuTableClient(): TableClient {
  const settings = getAppSettings();
  return TableClient.fromConnectionString(
    settings.storageConnectionString,
    settings.vmSkuTableName,
  );
}

function getPricingRefreshQueueClient() {
  const settings = getAppSettings();
  return getQueueServiceClient().getQueueClient(settings.pricingRefreshQueueName);
}

function getVmSkuRefreshQueueClient() {
  const settings = getAppSettings();
  return getQueueServiceClient().getQueueClient(settings.vmSkuRefreshQueueName);
}

function isNotFoundError(error: unknown): boolean {
  if (!(error instanceof Error)) {
    return false;
  }

  const candidate = error as Error & {
    statusCode?: number;
    code?: string;
  };

  return candidate.statusCode === 404 || candidate.code === "ResourceNotFound";
}

function parseConnectionString(
  connectionString: string,
): Record<string, string> {
  return connectionString
    .split(";")
    .map((segment) => segment.trim())
    .filter((segment) => segment.length > 0)
    .reduce<Record<string, string>>((accumulator, segment) => {
      const separatorIndex = segment.indexOf("=");
      if (separatorIndex > -1) {
        const key = segment.slice(0, separatorIndex);
        const value = segment.slice(separatorIndex + 1);
        accumulator[key] = value;
      }

      return accumulator;
    }, {});
}

function getSharedKeyCredential(): StorageSharedKeyCredential | null {
  const settings = getAppSettings();
  if (
    settings.storageConnectionString
      .trim()
      .startsWith(DEVELOPMENT_STORAGE_CONNECTION_PREFIX)
  ) {
    return new StorageSharedKeyCredential(
      DEVELOPMENT_STORAGE_ACCOUNT_NAME,
      DEVELOPMENT_STORAGE_ACCOUNT_KEY,
    );
  }

  const values = parseConnectionString(settings.storageConnectionString);
  if (!values.AccountName || !values.AccountKey) {
    return null;
  }

  return new StorageSharedKeyCredential(values.AccountName, values.AccountKey);
}

function getFallbackBlobUrl(blobPath: string): string {
  const settings = getAppSettings();
  if (
    settings.storageConnectionString
      .trim()
      .startsWith(DEVELOPMENT_STORAGE_CONNECTION_PREFIX)
  ) {
    return `http://127.0.0.1:10000/${DEVELOPMENT_STORAGE_ACCOUNT_NAME}/${settings.resultsContainer}/${blobPath}`;
  }

  const connectionValues = parseConnectionString(settings.storageConnectionString);
  const accountName = connectionValues.AccountName || "storage";
  const endpointSuffix = connectionValues.EndpointSuffix || "core.windows.net";
  const protocol = connectionValues.DefaultEndpointsProtocol || "https";
  return `${protocol}://${accountName}.blob.${endpointSuffix}/${settings.resultsContainer}/${blobPath}`;
}

function getArtifactBlobPath(
  artifacts: AssessmentArtifacts,
  artifactName: AssessmentArtifactName,
): string | undefined {
  switch (artifactName) {
    case "json":
      return artifacts.jsonBlobPath;
    case "csv":
      return artifacts.csvBlobPath;
    case "html":
      return artifacts.htmlBlobPath;
    case "log":
      return artifacts.logBlobPath;
    case "manifest":
      return artifacts.manifestBlobPath;
    default:
      return undefined;
  }
}

function buildJobRecord(entity: AssessmentJobEntity): AssessmentJobRecord {
  const request = JSON.parse(entity.requestJson) as AssessmentRequest;
  const clientId = normalizeClientId(entity.clientId || request.clientId);
  const artifacts: AssessmentArtifacts = {
    jsonBlobPath: entity.jsonBlobPath,
    csvBlobPath: entity.csvBlobPath,
    htmlBlobPath: entity.htmlBlobPath,
    logBlobPath: entity.logBlobPath,
    manifestBlobPath: entity.manifestBlobPath,
  };

  return {
    jobId: entity.jobId,
    clientId,
    tool: entity.tool,
    status: entity.status,
    requestedAt: entity.requestedAt,
    updatedAt: entity.updatedAt,
    startedAt: entity.startedAt,
    completedAt: entity.completedAt,
    requestedBy: entity.requestedBy,
    message: entity.message,
    request: {
      ...request,
      clientId,
    },
    artifacts,
  };
}

export async function ensureStorageReady(): Promise<void> {
  const settings = getAppSettings();
  const tableClient = getTableClient();
  await tableClient.createTable();
  await getPricingTableClient().createTable();
  await getVmSkuTableClient().createTable();

  const blobServiceClient = getBlobServiceClient();
  await blobServiceClient
    .getContainerClient(settings.resultsContainer)
    .createIfNotExists();
  await blobServiceClient
    .getContainerClient(settings.configContainer)
    .createIfNotExists();
  await blobServiceClient
    .getContainerClient(settings.referenceContainer)
    .createIfNotExists();
  await getQueueServiceClient()
    .getQueueClient(settings.queueName)
    .createIfNotExists();
  await getPricingRefreshQueueClient().createIfNotExists();
  await getVmSkuRefreshQueueClient().createIfNotExists();
}

export async function createAssessmentJob(
  jobId: string,
  request: AssessmentRequest,
): Promise<AssessmentJobRecord> {
  await ensureStorageReady();

  const now = new Date().toISOString();
  const clientId = normalizeClientId(request.clientId);
  const normalizedRequest: AssessmentRequest = {
    ...request,
    clientId,
  };
  const entity: AssessmentJobEntity = {
    partitionKey: getJobPartitionKey(clientId),
    rowKey: jobId,
    jobId,
    clientId,
    tool: normalizedRequest.tool,
    status: "Queued",
    requestedAt: now,
    updatedAt: now,
    requestedBy: normalizedRequest.requestedBy,
    requestJson: JSON.stringify(normalizedRequest),
    message: "Queued for execution",
  };

  const tableClient = getTableClient();
  await tableClient.createEntity(entity);
  return buildJobRecord(entity);
}

export async function getAssessmentJob(
  jobId: string,
): Promise<AssessmentJobRecord | null> {
  const tableClient = getTableClient();
  const entities = tableClient.listEntities<AssessmentJobEntity>({
    queryOptions: {
      filter: `RowKey eq '${escapeODataString(jobId)}'`,
    },
  });

  for await (const entity of entities) {
    return buildJobRecord(entity);
  }

  return null;
}

export async function listAssessmentJobs(
  limit = 25,
  clientId?: string,
): Promise<AssessmentJobRecord[]> {
  const tableClient = getTableClient();
  const jobs: AssessmentJobRecord[] = [];
  const filter = clientId
    ? `PartitionKey eq '${escapeODataString(getJobPartitionKey(clientId))}'`
    : undefined;
  const entities = tableClient.listEntities<AssessmentJobEntity>(
    filter
      ? {
          queryOptions: {
            filter,
          },
        }
      : undefined,
  );

  for await (const entity of entities) {
    jobs.push(buildJobRecord(entity));
  }

  return jobs
    .sort((left, right) => right.requestedAt.localeCompare(left.requestedAt))
    .slice(0, limit);
}

export async function updateAssessmentJob(
  jobId: string,
  patch: Partial<AssessmentJobEntity>,
): Promise<AssessmentJobRecord> {
  const existing = await getAssessmentJob(jobId);
  if (!existing) {
    throw new Error(`Assessment job not found: ${jobId}`);
  }

  const entity: AssessmentJobEntity = {
    partitionKey: getJobPartitionKey(existing.clientId),
    rowKey: jobId,
    jobId,
    clientId: existing.clientId,
    tool: existing.tool,
    status: existing.status,
    requestedAt: existing.requestedAt,
    updatedAt: new Date().toISOString(),
    startedAt: existing.startedAt,
    completedAt: existing.completedAt,
    requestedBy: existing.requestedBy,
    message: existing.message,
    requestJson: JSON.stringify({
      ...existing.request,
      clientId: existing.clientId,
    }),
    jsonBlobPath: existing.artifacts?.jsonBlobPath,
    csvBlobPath: existing.artifacts?.csvBlobPath,
    htmlBlobPath: existing.artifacts?.htmlBlobPath,
    logBlobPath: existing.artifacts?.logBlobPath,
    manifestBlobPath: existing.artifacts?.manifestBlobPath,
    ...patch,
  };

  const tableClient = getTableClient();
  await tableClient.upsertEntity(entity, "Replace");
  return buildJobRecord(entity);
}

export async function updateAssessmentStatus(
  jobId: string,
  status: AssessmentJobStatus,
  message?: string,
): Promise<AssessmentJobRecord> {
  const patch: Partial<AssessmentJobEntity> = { status };
  if (message) {
    patch.message = message;
  }

  if (status === "Running") {
    patch.startedAt = new Date().toISOString();
  }

  if (status === "Completed" || status === "Failed") {
    patch.completedAt = new Date().toISOString();
  }

  return updateAssessmentJob(jobId, patch);
}

export async function uploadLocalFileToResults(
  localPath: string,
  blobPath: string,
): Promise<string> {
  const settings = getAppSettings();
  const blobClient = getBlobServiceClient()
    .getContainerClient(settings.resultsContainer)
    .getBlockBlobClient(blobPath);
  await blobClient.uploadFile(localPath);
  return blobPath;
}

export async function uploadTextToResults(
  blobPath: string,
  content: string,
  contentType: string,
): Promise<string> {
  const settings = getAppSettings();
  const blobClient = getBlobServiceClient()
    .getContainerClient(settings.resultsContainer)
    .getBlockBlobClient(blobPath);
  await blobClient.upload(content, Buffer.byteLength(content), {
    blobHTTPHeaders: {
      blobContentType: contentType,
    },
  });
  return blobPath;
}

export async function getArtifactLink(
  artifactName: AssessmentArtifactName,
  blobPath: string,
  expiresInMinutes = 15,
): Promise<AssessmentArtifactLink> {
  const blobClient = getResultsContainerClient().getBlobClient(blobPath);
  const properties = await blobClient.getProperties();
  const fallbackUrl = getFallbackBlobUrl(blobPath);
  const sharedKeyCredential = getSharedKeyCredential();

  if (!sharedKeyCredential) {
    return {
      name: artifactName,
      blobPath,
      url: fallbackUrl,
      contentType: properties.contentType,
      sizeInBytes: properties.contentLength,
    };
  }

  const expiresOn = new Date(Date.now() + expiresInMinutes * 60 * 1000);
  const sas = generateBlobSASQueryParameters(
    {
      containerName: getAppSettings().resultsContainer,
      blobName: blobPath,
      permissions: BlobSASPermissions.parse("r"),
      expiresOn,
    },
    sharedKeyCredential,
  ).toString();

  return {
    name: artifactName,
    blobPath,
    url: `${fallbackUrl}?${sas}`,
    expiresAt: expiresOn.toISOString(),
    contentType: properties.contentType,
    sizeInBytes: properties.contentLength,
  };
}

export async function getJobArtifactLinks(
  job: AssessmentJobRecord,
): Promise<Partial<Record<AssessmentArtifactName, AssessmentArtifactLink>>> {
  const links: Partial<Record<AssessmentArtifactName, AssessmentArtifactLink>> = {};

  for (const artifactName of ["json", "csv", "html", "log", "manifest"] as AssessmentArtifactName[]) {
    const blobPath = getArtifactBlobPath(job.artifacts || {}, artifactName);
    if (!blobPath) {
      continue;
    }

    links[artifactName] = await getArtifactLink(artifactName, blobPath);
  }

  return links;
}

export async function readResultBlobText(blobPath: string): Promise<string> {
  const blobClient = getResultsContainerClient().getBlobClient(blobPath);
  const response = await blobClient.download();
  const chunks: Buffer[] = [];
  for await (const chunk of response.readableStreamBody ?? []) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }

  return Buffer.concat(chunks).toString("utf8");
}

export async function getAssessmentManifest(
  job: AssessmentJobRecord,
): Promise<AssessmentManifest | undefined> {
  const blobPath = job.artifacts?.manifestBlobPath;
  if (!blobPath) {
    return undefined;
  }

  const content = await readResultBlobText(blobPath);
  return JSON.parse(content) as AssessmentManifest;
}

export function resolveArtifactBlobPath(
  job: AssessmentJobRecord,
  artifactName: AssessmentArtifactName,
): string | undefined {
  return getArtifactBlobPath(job.artifacts || {}, artifactName);
}

export async function downloadConfigBlob(
  blobPath: string,
): Promise<Buffer> {
  const settings = getAppSettings();
  const blobClient = getBlobServiceClient()
    .getContainerClient(settings.configContainer)
    .getBlobClient(blobPath);
  const response = await blobClient.download();
  const chunks: Buffer[] = [];
  for await (const chunk of response.readableStreamBody ?? []) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }

  return Buffer.concat(chunks);
}

export async function getPricingCacheEntity(
  partitionKey: string,
  rowKey: string,
): Promise<PricingCacheEntity | null> {
  try {
    return await getPricingTableClient().getEntity<PricingCacheEntity>(
      partitionKey,
      rowKey,
    );
  } catch (error: unknown) {
    if (isNotFoundError(error)) {
      return null;
    }

    throw error;
  }
}

export async function upsertPricingCacheEntity(
  entity: PricingCacheEntity,
): Promise<void> {
  await ensureStorageReady();
  await getPricingTableClient().upsertEntity(entity, "Replace");
}

export async function enqueuePricingRefresh(
  message: PricingRefreshQueueMessage,
): Promise<void> {
  await ensureStorageReady();
  await getPricingRefreshQueueClient().sendMessage(JSON.stringify(message));
}

export async function getVmSkuCatalogMetadataEntity(
  partitionKey: string,
  rowKey: string,
): Promise<VmSkuCatalogMetadataEntity | null> {
  try {
    return await getVmSkuTableClient().getEntity<VmSkuCatalogMetadataEntity>(
      partitionKey,
      rowKey,
    );
  } catch (error: unknown) {
    if (isNotFoundError(error)) {
      return null;
    }

    throw error;
  }
}

export async function listVmSkuCatalogEntities(
  partitionKey: string,
): Promise<VmSkuCatalogEntity[]> {
  const tableClient = getVmSkuTableClient();
  const entities = tableClient.listEntities<VmSkuCatalogEntity>({
    queryOptions: {
      filter: `PartitionKey eq '${escapeODataString(partitionKey)}'`,
    },
  });

  const items: VmSkuCatalogEntity[] = [];
  for await (const entity of entities) {
    items.push(entity);
  }

  return items;
}

export async function upsertVmSkuCatalogMetadataEntity(
  entity: VmSkuCatalogMetadataEntity,
): Promise<void> {
  await ensureStorageReady();
  await getVmSkuTableClient().upsertEntity(entity, "Replace");
}

export async function upsertVmSkuCatalogEntities(
  entities: VmSkuCatalogEntity[],
): Promise<void> {
  if (entities.length === 0) {
    return;
  }

  await ensureStorageReady();
  const tableClient = getVmSkuTableClient();
  for (const entity of entities) {
    await tableClient.upsertEntity(entity, "Replace");
  }
}

export async function enqueueVmSkuCatalogRefresh(
  message: VmSkuCatalogRefreshQueueMessage,
): Promise<void> {
  await ensureStorageReady();
  await getVmSkuRefreshQueueClient().sendMessage(JSON.stringify(message));
}