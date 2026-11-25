/**
 * Planned Jenkins Integration Abstraction (ADR 009 / Checkpoint 6.2).
 * Interface contracts only in Checkpoint 6.1; mock and private-network HTTP
 * implementations will be wired in Checkpoint 6.2.
 */

export interface JenkinsTriggerResult {
  queueId: number;
}

export interface JenkinsQueueResolution {
  resolved: boolean;
  cancelled: boolean;
  buildNumber: number | null;
}

export interface JenkinsBuildStatus {
  building: boolean;
  result: 'SUCCESS' | 'FAILURE' | 'ABORTED' | 'UNSTABLE' | null;
  durationMs: number | null;
}

export interface JenkinsArtifacts {
  metrics: Record<string, unknown>;
  summaryMarkdown: string;
  charts: {
    commitsPerAuthorPng: Buffer | null;
    dailyActivityPng: Buffer | null;
  };
}

export interface IJenkinsClient {
  triggerJob(repositoryUrl: string): Promise<JenkinsTriggerResult>;
  getBuildFromQueue(queueId: number): Promise<JenkinsQueueResolution>;
  getBuildStatus(buildNumber: number): Promise<JenkinsBuildStatus>;
  fetchArtifact(buildNumber: number): Promise<JenkinsArtifacts>;
}
