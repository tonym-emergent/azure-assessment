export type AssessmentTool = "vm";

export const DEFAULT_CLIENT_ID = "default";

export type AssessmentJobStatus =
  | "Created"
  | "Queued"
  | "Running"
  | "Completed"
  | "Failed";

export interface AssessmentRequest {
  tool: AssessmentTool;
  clientId?: string;
  assessmentProfileId?: string;
  targetTenantId?: string;
  subscriptionIds?: string[];
  vmNames?: string[];
  daysToInspect?: number;
  configBlobPath?: string;
  refreshAdvisor?: boolean;
  outputPrefix?: string;
  requestedBy?: string;
}

export interface AssessmentQueueMessage {
  jobId: string;
  clientId?: string;
}

export interface PricingLookupRequest {
  armRegionName: string;
  armSkuName: string;
  osType: string;
  licenseType?: string;
}

export type PricingRefreshReason = "CacheMiss" | "Stale" | "Manual";

export interface PricingRefreshQueueMessage extends PricingLookupRequest {
  reason: PricingRefreshReason;
  requestedAt: string;
}

export interface PricingModel {
  CurrencyCode: string;
  PaygHourly: number;
  PaygMonthly: number;
  PaygComputeMonthly: number;
  Reservation1YearTotal: number;
  Reservation1YearMonthly: number;
  Reservation1YearComputeMonthly: number;
  Reservation3YearTotal: number;
  Reservation3YearMonthly: number;
  Reservation3YearComputeMonthly: number;
  IncludeOsLicense: boolean;
  LicenseBenefitApplied: boolean;
  OsLicenseHourly: number;
  OsLicenseMonthly: number;
  OsLicenseStatus: string;
  PricingStatus: string;
  PaygMatchType: string;
  Reservation1YearMatchType: string;
  Reservation3YearMatchType: string;
  MeterName: string;
  ProductName: string;
}

export interface PricingCacheRecord {
  key: string;
  lookup: PricingLookupRequest;
  model: PricingModel;
  cacheStatus: "Hit" | "Miss" | "Stale" | "Live";
  fetchedAt: string;
  expiresAt: string;
}

export interface PricingCacheEntity extends PricingModel {
  partitionKey: string;
  rowKey: string;
  armRegionName: string;
  armSkuName: string;
  osType: string;
  licenseType?: string;
  licenseMode: string;
  fetchedAt: string;
  expiresAt: string;
  source: string;
}

export interface VmSkuSpec {
  Name: string;
  Family: string;
  VCpu: number;
  MemoryGB: number;
  MaxDataDiskCount: number;
  PremiumIO: string;
}

export interface VmSkuCatalogLookupRequest {
  location: string;
  families?: string[];
}

export type VmSkuCatalogRefreshReason =
  | "CacheMiss"
  | "Stale"
  | "Scheduled"
  | "Manual";

export interface VmSkuCatalogRefreshQueueMessage extends VmSkuCatalogLookupRequest {
  reason: VmSkuCatalogRefreshReason;
  requestedAt: string;
}

export interface VmSkuCatalogCacheRecord {
  key: string;
  request: VmSkuCatalogLookupRequest;
  items: VmSkuSpec[];
  cacheStatus: "Hit" | "Miss" | "Stale" | "Live";
  fetchedAt: string;
  expiresAt: string;
  refreshId: string;
}

export interface VmSkuCatalogMetadataEntity {
  partitionKey: string;
  rowKey: string;
  entityType: "metadata";
  location: string;
  familyKey: string;
  refreshId: string;
  fetchedAt: string;
  expiresAt: string;
  itemCount: number;
  source: string;
}

export interface VmSkuCatalogEntity {
  partitionKey: string;
  rowKey: string;
  entityType: "sku";
  location: string;
  skuName: string;
  family: string;
  vCpu: number;
  memoryGB: number;
  maxDataDiskCount: number;
  premiumIO: string;
  refreshId: string;
  fetchedAt: string;
  expiresAt: string;
}

export interface AssessmentArtifacts {
  jsonBlobPath?: string;
  csvBlobPath?: string;
  htmlBlobPath?: string;
  logBlobPath?: string;
  manifestBlobPath?: string;
}

export type AssessmentArtifactName =
  | "json"
  | "csv"
  | "html"
  | "log"
  | "manifest";

export interface AssessmentArtifactLink {
  name: AssessmentArtifactName;
  blobPath: string;
  url: string;
  expiresAt?: string;
  contentType?: string;
  sizeInBytes?: number;
}

export interface AssessmentJobRecord {
  jobId: string;
  clientId: string;
  tool: AssessmentTool;
  status: AssessmentJobStatus;
  requestedAt: string;
  updatedAt: string;
  startedAt?: string;
  completedAt?: string;
  requestedBy?: string;
  message?: string;
  request: AssessmentRequest;
  artifacts?: AssessmentArtifacts;
}

export interface AssessmentManifest {
  jobId: string;
  clientId: string;
  tool: AssessmentTool;
  status: AssessmentJobStatus;
  createdAt: string;
  artifacts: AssessmentArtifacts;
}

export interface AssessmentResultsResponse {
  job: AssessmentJobRecord;
  manifest?: AssessmentManifest;
  artifacts: Partial<Record<AssessmentArtifactName, AssessmentArtifactLink>>;
}

export interface AssessmentJobEntity {
  partitionKey: string;
  rowKey: string;
  jobId: string;
  clientId: string;
  tool: AssessmentTool;
  status: AssessmentJobStatus;
  requestedAt: string;
  updatedAt: string;
  startedAt?: string;
  completedAt?: string;
  requestedBy?: string;
  message?: string;
  requestJson: string;
  jsonBlobPath?: string;
  csvBlobPath?: string;
  htmlBlobPath?: string;
  logBlobPath?: string;
  manifestBlobPath?: string;
}