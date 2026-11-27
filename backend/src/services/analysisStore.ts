import { randomUUID } from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { z } from 'zod';
import { AnalysisErrorInfo, AnalysisRecord } from '../types/analysis';

const SCHEMA_VERSION = 1;
const TEMP_FILE_PREFIX = '.analyses.json.tmp.';

const AnalysisErrorInfoSchema = z.object({
  code: z.string().min(1),
  message: z.string().min(1),
});

const StoredAnalysisResultsSchema = z.object({
  metrics: z.record(z.unknown()),
  summaryMarkdown: z.string(),
  charts: z.object({
    commitsPerAuthor: z.string().nullable(),
    dailyActivity: z.string().nullable(),
  }),
});

const AnalysisRecordSchema = z.object({
  analysisId: z.string().uuid(),
  repositoryUrl: z.string().min(1),
  status: z.enum(['QUEUED', 'BUILDING', 'COMPLETED', 'FAILED', 'CANCELLED']),
  progress: z.string(),
  createdAt: z.string().min(1),
  updatedAt: z.string().min(1),
  error: AnalysisErrorInfoSchema.nullable(),
  queueId: z.number().int().nullable(),
  buildNumber: z.number().int().nullable(),
  results: StoredAnalysisResultsSchema.nullable(),
});

const PersistedStoreSchema = z.object({
  schemaVersion: z.literal(SCHEMA_VERSION),
  updatedAt: z.string().min(1),
  analyses: z.record(AnalysisRecordSchema),
});

export interface StoreRecoveryOptions {
  /**
   * Maximum age for QUEUED/BUILDING records with existing Jenkins IDs before they
   * are transitioned to FAILED on startup recovery.
   */
  maxInFlightAgeMs?: number;
  /**
   * When true, marks ALL QUEUED/BUILDING records as FAILED on restart (useful when
   * no active poller/controller owns interrupted jobs). When false, preserves only
   * non-expired jobs that already have a persisted queueId or buildNumber.
   */
  failAllInFlightOnRestart?: boolean;
  /** Clock override for deterministic testing. */
  now?: () => Date;
}

export interface StoreRecoverySummary {
  totalLoaded: number;
  preservedCompleted: number;
  preservedTerminalOther: number;
  recoveredInFlight: number;
  failedInterrupted: number;
}

/**
 * Lightweight atomic JSON disk-backed store for analysis records.
 * - Serializes concurrent writes via an internal promise mutex.
 * - Persists via same-directory temp file + fsync + POSIX atomic rename.
 * - Recovers completed/failed/cancelled history and transitions orphaned in-flight
 *   jobs cleanly across backend restarts.
 */
export class FileAnalysisStore {
  public readonly dataDir: string;
  public readonly stateFilePath: string;

  private readonly records = new Map<string, AnalysisRecord>();
  private writeQueue: Promise<void> = Promise.resolve();
  private initialized = false;

  constructor(dataDir: string) {
    this.dataDir = path.resolve(dataDir);
    this.stateFilePath = path.join(this.dataDir, 'analyses.json');
  }

  public isInitialized(): boolean {
    return this.initialized;
  }

  /**
   * Loads existing persisted analyses, cleans up stale temp files, applies explicit
   * restart recovery rules for QUEUED/BUILDING jobs, and persists recovery transitions.
   */
  public async initialize(options: StoreRecoveryOptions = {}): Promise<StoreRecoverySummary> {
    const maxInFlightAgeMs = options.maxInFlightAgeMs ?? 600_000;
    const failAllInFlightOnRestart = options.failAllInFlightOnRestart ?? false;
    const nowFn = options.now ?? (() => new Date());

    await fs.mkdir(this.dataDir, { recursive: true, mode: 0o750 });
    await this.cleanupOrphanTempFiles();

    this.records.clear();

    let rawJson: string | null = null;
    try {
      rawJson = await fs.readFile(this.stateFilePath, 'utf8');
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code;
      if (code !== 'ENOENT') {
        throw err;
      }
    }

    if (rawJson !== null) {
      let decoded: unknown;
      try {
        decoded = JSON.parse(rawJson);
      } catch (err) {
        throw new Error(
          `Corrupt analysis store JSON at "${this.stateFilePath}": ${err instanceof Error ? err.message : String(err)}`,
        );
      }

      const parsed = PersistedStoreSchema.safeParse(decoded);
      if (!parsed.success) {
        const msg = parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('; ');
        throw new Error(`Invalid analysis store schema at "${this.stateFilePath}": ${msg}`);
      }

      for (const [id, record] of Object.entries(parsed.data.analyses)) {
        this.records.set(id, structuredClone(record));
      }
    }

    const summary = this.recoverInFlightRecords(nowFn(), maxInFlightAgeMs, failAllInFlightOnRestart);

    if (rawJson === null || summary.failedInterrupted > 0) {
      await this.persistAtomically(nowFn().toISOString());
    }

    this.initialized = true;
    return summary;
  }

  private recoverInFlightRecords(
    now: Date,
    maxInFlightAgeMs: number,
    failAllInFlightOnRestart: boolean,
  ): StoreRecoverySummary {
    let preservedCompleted = 0;
    let preservedTerminalOther = 0;
    let recoveredInFlight = 0;
    let failedInterrupted = 0;

    const nowMs = now.getTime();
    const nowIso = now.toISOString();

    for (const [id, record] of this.records.entries()) {
      if (record.status === 'COMPLETED') {
        preservedCompleted += 1;
        continue;
      }
      if (record.status === 'FAILED' || record.status === 'CANCELLED') {
        preservedTerminalOther += 1;
        continue;
      }

      const hasJenkinsHandle = record.queueId !== null || record.buildNumber !== null;
      const createdMs = Date.parse(record.createdAt);
      const isExpired = !Number.isFinite(createdMs) || nowMs - createdMs > maxInFlightAgeMs;

      let failureError: AnalysisErrorInfo | null = null;
      if (failAllInFlightOnRestart) {
        failureError = {
          code: 'INTERRUPTED_ON_RESTART',
          message: 'Backend restarted while analysis was in progress; please resubmit repository.',
        };
      } else if (!hasJenkinsHandle) {
        failureError = {
          code: 'INTERRUPTED_ON_RESTART',
          message: 'Backend restarted before Jenkins job dispatch completed; please resubmit repository.',
        };
      } else if (isExpired) {
        failureError = {
          code: 'STALE_ON_RESTART',
          message: 'In-flight analysis exceeded maximum lifetime across backend restart.',
        };
      }

      if (failureError !== null) {
        this.records.set(id, {
          ...record,
          status: 'FAILED',
          progress: 'Interrupted during backend restart',
          updatedAt: nowIso,
          error: failureError,
        });
        failedInterrupted += 1;
      } else {
        recoveredInFlight += 1;
      }
    }

    return {
      totalLoaded: this.records.size,
      preservedCompleted,
      preservedTerminalOther,
      recoveredInFlight,
      failedInterrupted,
    };
  }

  public async save(record: AnalysisRecord): Promise<AnalysisRecord> {
    this.assertReady();
    return this.enqueueWrite(async () => {
      const clone = structuredClone(record);
      this.records.set(clone.analysisId, clone);
      await this.persistAtomically(clone.updatedAt);
      return structuredClone(clone);
    });
  }

  public async update(
    analysisId: string,
    mutator: (current: AnalysisRecord) => AnalysisRecord,
  ): Promise<AnalysisRecord | null> {
    this.assertReady();
    return this.enqueueWrite(async () => {
      const existing = this.records.get(analysisId);
      if (!existing) {
        return null;
      }
      const next = structuredClone(mutator(structuredClone(existing)));
      this.records.set(analysisId, next);
      await this.persistAtomically(next.updatedAt);
      return structuredClone(next);
    });
  }

  public getById(analysisId: string): AnalysisRecord | null {
    const found = this.records.get(analysisId);
    return found ? structuredClone(found) : null;
  }

  public listAll(): AnalysisRecord[] {
    return Array.from(this.records.values(), (record) => structuredClone(record));
  }

  public listResumableInFlight(): AnalysisRecord[] {
    return Array.from(this.records.values())
      .filter(
        (record) =>
          (record.status === 'QUEUED' || record.status === 'BUILDING') &&
          (record.queueId !== null || record.buildNumber !== null),
      )
      .map((record) => structuredClone(record));
  }

  private assertReady(): void {
    if (!this.initialized) {
      throw new Error('FileAnalysisStore must be initialized before reading or writing records');
    }
  }

  private enqueueWrite<T>(task: () => Promise<T>): Promise<T> {
    const run = this.writeQueue.then(task, task);
    this.writeQueue = run.then(
      () => undefined,
      () => undefined,
    );
    return run;
  }

  /**
   * Serializes store snapshot and writes via temp file + fsync + atomic rename
   * inside the same directory to prevent partial writes from corrupting analyses.json.
   */
  private async persistAtomically(updatedAt: string): Promise<void> {
    const payload = {
      schemaVersion: SCHEMA_VERSION,
      updatedAt,
      analyses: Object.fromEntries(this.records.entries()),
    };
    const serialized = `${JSON.stringify(payload, null, 2)}\n`;
    const tmpPath = path.join(this.dataDir, `${TEMP_FILE_PREFIX}${process.pid}.${randomUUID()}`);

    const handle = await fs.open(tmpPath, 'w', 0o640);
    try {
      await handle.writeFile(serialized, 'utf8');
      await handle.sync();
    } catch (err) {
      await handle.close().catch(() => undefined);
      await fs.rm(tmpPath, { force: true }).catch(() => undefined);
      throw err;
    }

    await handle.close();

    try {
      await fs.rename(tmpPath, this.stateFilePath);
    } catch (err) {
      await fs.rm(tmpPath, { force: true }).catch(() => undefined);
      throw err;
    }
  }

  private async cleanupOrphanTempFiles(): Promise<void> {
    const entries = await fs.readdir(this.dataDir, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.isFile() && entry.name.startsWith(TEMP_FILE_PREFIX)) {
        await fs.rm(path.join(this.dataDir, entry.name), { force: true }).catch(() => undefined);
      }
    }
  }
}
