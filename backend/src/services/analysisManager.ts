import { randomUUID } from 'node:crypto';
import {
  AnalysisAcceptedResponse,
  AnalysisPublicStatus,
  AnalysisRecord,
  AnalysisResultsResponse,
  toPublicResults,
  toPublicStatus,
} from '../types/analysis';
import { ConflictError, NotFoundError, ServiceUnavailableError } from '../utils/errors';
import {
  RepositoryValidationOptions,
  ValidatedRepositoryUrl,
  validateRepositoryUrlWithSsrfGuard,
} from '../validators/repoValidator';
import { FileAnalysisStore } from './analysisStore';
import { ArtifactIngestor, ArtifactValidationError, assertValidAnalysisUuid, isValidChartFileName } from './artifactIngestion';
import { ValidationError } from '../utils/errors';
import { IJenkinsClient } from './jenkinsClient';

export type ValidateRepositoryFn = (
  rawInput: unknown,
  options?: RepositoryValidationOptions,
) => Promise<ValidatedRepositoryUrl>;

export interface AnalysisManagerOptions {
  store: FileAnalysisStore;
  artifactIngestor: ArtifactIngestor;
  jenkinsClient: IJenkinsClient;
  ssrfCheckDns: boolean;
  analysisTimeoutMs: number;
  pollIntervalMs: number;
  validateRepository?: ValidateRepositoryFn;
  now?: () => number;
}

/**
 * Coordinates submission, persistence, Jenkins polling, artifact ingestion,
 * restart recovery, and strict redaction of internal CI identifiers.
 */
export class AnalysisManager {
  private readonly store: FileAnalysisStore;
  private readonly artifactIngestor: ArtifactIngestor;
  private readonly jenkinsClient: IJenkinsClient;
  private readonly ssrfCheckDns: boolean;
  private readonly analysisTimeoutMs: number;
  private readonly pollIntervalMs: number;
  private readonly validateRepository: ValidateRepositoryFn;
  private readonly now: () => number;

  private readonly pollTimers = new Map<string, NodeJS.Timeout>();
  private readonly inFlightTicks = new Map<string, Promise<void>>();
  private stopped = false;

  constructor(options: AnalysisManagerOptions) {
    this.store = options.store;
    this.artifactIngestor = options.artifactIngestor;
    this.jenkinsClient = options.jenkinsClient;
    this.ssrfCheckDns = options.ssrfCheckDns;
    this.analysisTimeoutMs = options.analysisTimeoutMs;
    this.pollIntervalMs = options.pollIntervalMs;
    this.validateRepository = options.validateRepository ?? validateRepositoryUrlWithSsrfGuard;
    this.now = options.now ?? (() => Date.now());
  }

  public async submitAnalysis(rawRepositoryUrl: unknown): Promise<AnalysisAcceptedResponse> {
    const validated = await this.validateRepository(rawRepositoryUrl, {
      checkDns: this.ssrfCheckDns,
    });

    const analysisId = randomUUID();
    const createdAt = new Date(this.now()).toISOString();

    const initialRecord: AnalysisRecord = {
      analysisId,
      repositoryUrl: validated.canonicalUrl,
      status: 'QUEUED',
      progress: 'Submission accepted; dispatching analysis job...',
      createdAt,
      updatedAt: createdAt,
      error: null,
      queueId: null,
      buildNumber: null,
      results: null,
    };

    // Persist before external dispatch so crash consistency is preserved cleanly
    await this.store.save(initialRecord);

    let queueId: number;
    try {
      const dispatchRes = await this.jenkinsClient.triggerJob(validated.canonicalUrl);
      queueId = dispatchRes.queueId;
    } catch {
      const failedAt = new Date(this.now()).toISOString();
      await this.store.update(analysisId, (cur) => ({
        ...cur,
        status: 'FAILED',
        progress: 'Analysis dispatch failed',
        updatedAt: failedAt,
        error: {
          code: 'DISPATCH_FAILED',
          message: 'Failed to dispatch repository analysis job to CI controller',
        },
      }));
      throw new ServiceUnavailableError(
        'Analysis controller could not accept the analysis job at this time',
        { analysisId },
      );
    }

    await this.store.update(analysisId, (cur) => ({
      ...cur,
      queueId,
      progress: 'Queued for containerized analysis...',
      updatedAt: new Date(this.now()).toISOString(),
    }));

    this.ensurePolling(analysisId);

    return {
      analysisId,
      status: 'QUEUED',
      createdAt,
    };
  }

  public getPublicStatus(analysisId: string): AnalysisPublicStatus {
    assertValidAnalysisUuid(analysisId);
    const record = this.store.getById(analysisId);
    if (!record) {
      throw new NotFoundError(`Analysis "${analysisId}" was not found`);
    }
    return toPublicStatus(record);
  }

  public getPublicResults(analysisId: string): AnalysisResultsResponse {
    assertValidAnalysisUuid(analysisId);
    const record = this.store.getById(analysisId);
    if (!record) {
      throw new NotFoundError(`Analysis "${analysisId}" was not found`);
    }
    if (record.status !== 'COMPLETED' || record.results === null) {
      throw new ConflictError(
        `Analysis results are not available while status is "${record.status}"`,
        { status: record.status },
      );
    }
    return toPublicResults(record);
  }

  public async getChartArtifact(analysisId: string, chartName: string): Promise<Buffer> {
    assertValidAnalysisUuid(analysisId);
    if (!isValidChartFileName(chartName)) {
      throw new ValidationError(
        `Invalid chart name "${chartName}". Permitted charts: commits_per_author.png, daily_commit_activity.png`,
      );
    }

    const record = this.store.getById(analysisId);
    if (!record) {
      throw new NotFoundError(`Analysis "${analysisId}" was not found`);
    }
    if (record.status !== 'COMPLETED' || record.results === null) {
      throw new ConflictError(
        `Chart artifacts are not available while status is "${record.status}"`,
        { status: record.status },
      );
    }

    return this.artifactIngestor.readCachedChart(analysisId, chartName);
  }

  /**
   * Resumes status polling solely for persisted in-flight analyses that already hold a
   * Jenkins queueId or buildNumber, ensuring no duplicate job submissions occur.
   */
  public resumePendingAnalyses(): number {
    const pending = this.store.listResumableInFlight();
    for (const record of pending) {
      this.ensurePolling(record.analysisId);
    }
    return pending.length;
  }

  public async stop(): Promise<void> {
    this.stopped = true;
    for (const timer of this.pollTimers.values()) {
      clearTimeout(timer);
    }
    this.pollTimers.clear();
    await Promise.allSettled(Array.from(this.inFlightTicks.values()));
  }

  public ensurePolling(analysisId: string): void {
    if (this.stopped || this.pollTimers.has(analysisId)) {
      return;
    }

    const scheduleNext = () => {
      if (this.stopped) {
        return;
      }
      const timer = setTimeout(() => {
        this.pollTimers.delete(analysisId);
        void this.runGuardedTick(analysisId).then((shouldContinue) => {
          if (shouldContinue && !this.stopped) {
            scheduleNext();
          }
        });
      }, this.pollIntervalMs);
      timer.unref();
      this.pollTimers.set(analysisId, timer);
    };

    scheduleNext();
  }

  private runGuardedTick(analysisId: string): Promise<boolean> {
    const existing = this.inFlightTicks.get(analysisId);
    if (existing) {
      return existing.then(() => false);
    }

    let shouldContinue = false;
    const tickPromise = this.pollOnce(analysisId)
      .then((cont) => {
        shouldContinue = cont;
      })
      .finally(() => {
        this.inFlightTicks.delete(analysisId);
      });

    this.inFlightTicks.set(analysisId, tickPromise);
    return tickPromise.then(() => shouldContinue);
  }

  /**
   * Executes one deterministic polling step for an analysis record.
   * Returns true if polling should continue, false once a terminal state is reached.
   */
  public async pollOnce(analysisId: string): Promise<boolean> {
    if (this.stopped) {
      return false;
    }

    const record = this.store.getById(analysisId);
    if (!record || (record.status !== 'QUEUED' && record.status !== 'BUILDING')) {
      return false;
    }

    const nowMs = this.now();
    const createdMs = Date.parse(record.createdAt);
    if (Number.isFinite(createdMs) && nowMs - createdMs > this.analysisTimeoutMs) {
      await this.markFailed(
        analysisId,
        'ANALYSIS_TIMEOUT',
        'Repository analysis exceeded maximum configured execution time limit',
      );
      return false;
    }

    try {
      if (record.buildNumber === null) {
        if (record.queueId === null) {
          await this.markFailed(
            analysisId,
            'INTERNAL_STATE_ERROR',
            'Queued analysis is missing internal queue tracking state',
          );
          return false;
        }

        const queueRes = await this.jenkinsClient.getBuildFromQueue(record.queueId);
        if (queueRes.cancelled) {
          await this.store.update(analysisId, (cur) => ({
            ...cur,
            status: 'CANCELLED',
            progress: 'Analysis job was cancelled in queue',
            updatedAt: new Date(this.now()).toISOString(),
            error: null,
          }));
          return false;
        }

        if (!queueRes.resolved || queueRes.buildNumber === null) {
          return true;
        }

        await this.store.update(analysisId, (cur) => ({
          ...cur,
          status: 'BUILDING',
          buildNumber: queueRes.buildNumber,
          progress: 'Analyzing commits, metrics, charts, and insights...',
          updatedAt: new Date(this.now()).toISOString(),
        }));

        return true;
      }

      const status = await this.jenkinsClient.getBuildStatus(record.buildNumber);
      if (status.building || status.result === null) {
        return true;
      }

      if (status.result === 'ABORTED') {
        await this.store.update(analysisId, (cur) => ({
          ...cur,
          status: 'CANCELLED',
          progress: 'Analysis job was aborted',
          updatedAt: new Date(this.now()).toISOString(),
          error: null,
        }));
        return false;
      }

      if (status.result !== 'SUCCESS') {
        await this.markFailed(
          analysisId,
          'ANALYSIS_FAILED',
          `Repository analysis pipeline ended with status ${status.result}`,
        );
        return false;
      }

      const rawBundle = await this.jenkinsClient.fetchArtifact(record.buildNumber);
      const ingested = await this.artifactIngestor.ingestAndCache(analysisId, rawBundle);

      await this.store.update(analysisId, (cur) => ({
        ...cur,
        status: 'COMPLETED',
        progress: 'Analysis completed',
        updatedAt: new Date(this.now()).toISOString(),
        error: null,
        results: ingested,
      }));
      return false;
    } catch (err) {
      if (err instanceof ArtifactValidationError) {
        await this.markFailed(analysisId, 'ARTIFACT_INGESTION_FAILED', err.message);
        return false;
      }
      await this.markFailed(
        analysisId,
        'PIPELINE_POLL_FAILED',
        'Failed to retrieve or process repository analysis status',
      );
      return false;
    }
  }

  private async markFailed(analysisId: string, code: string, message: string): Promise<void> {
    await this.store.update(analysisId, (cur) => ({
      ...cur,
      status: 'FAILED',
      progress: 'Analysis failed',
      updatedAt: new Date(this.now()).toISOString(),
      error: { code, message },
    }));
  }
}
