/**
 * Jenkins Integration Abstraction (ADR 009 / Checkpoint 6.2).
 * Keeps all Jenkins queue IDs, build numbers, URLs, and credentials strictly
 * inside the backend service layer.
 */

export interface JenkinsTriggerResult {
  queueId: number;
}

export interface JenkinsQueueResolution {
  resolved: boolean;
  cancelled: boolean;
  buildNumber: number | null;
}

export type JenkinsTerminalResult = 'SUCCESS' | 'FAILURE' | 'ABORTED' | 'UNSTABLE';

export interface JenkinsBuildStatus {
  building: boolean;
  result: JenkinsTerminalResult | null;
  durationMs: number | null;
}

export interface JenkinsArtifactDescriptor {
  fileName: string;
  relativePath: string;
}

export interface JenkinsBuildResult {
  building: boolean;
  result: JenkinsTerminalResult | null;
  durationMs: number | null;
  artifacts: JenkinsArtifactDescriptor[];
}

export interface RawArtifactBundle {
  metricsJson: Buffer;
  summaryMarkdown: Buffer;
  commitsPerAuthorPng: Buffer | null;
  dailyActivityPng: Buffer | null;
}

export interface IJenkinsClient {
  triggerJob(repositoryUrl: string): Promise<JenkinsTriggerResult>;
  getBuildFromQueue(queueId: number): Promise<JenkinsQueueResolution>;
  getBuildStatus(buildNumber: number): Promise<JenkinsBuildStatus>;
  getBuildResult(buildNumber: number): Promise<JenkinsBuildResult>;
  fetchArtifact(buildNumber: number): Promise<RawArtifactBundle>;
}
