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