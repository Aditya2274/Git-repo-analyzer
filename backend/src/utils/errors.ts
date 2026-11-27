export type ApiErrorCode =
  | 'VALIDATION_ERROR'
  | 'INVALID_JSON'
  | 'SSRF_BLOCKED'
  | 'NOT_FOUND'
  | 'CONFLICT'
  | 'CORS_FORBIDDEN'
  | 'SERVICE_UNAVAILABLE'
  | 'INTERNAL_ERROR';

export interface ApiErrorPayload {
  error: {
    code: ApiErrorCode;
    message: string;
    details: unknown;
  };
}

/**
 * Base application error preserving HTTP status and structured API error metadata.
 */
export class AppError extends Error {
  public readonly statusCode: number;
  public readonly code: ApiErrorCode;
  public readonly details: unknown;

  constructor(
    statusCode: number,
    code: ApiErrorCode,
    message: string,
    details: unknown = null,
  ) {
    super(message);
    this.name = new.target.name;
    this.statusCode = statusCode;
    this.code = code;
    this.details = details;
  }
}

export class ValidationError extends AppError {
  constructor(message: string, details: unknown = null) {
    super(400, 'VALIDATION_ERROR', message, details);
  }
}

export class SsrfBlockedError extends AppError {
  constructor(message: string, details: unknown = null) {
    super(400, 'SSRF_BLOCKED', message, details);
  }
}

export class NotFoundError extends AppError {
  constructor(message: string, details: unknown = null) {
    super(404, 'NOT_FOUND', message, details);
  }
}

export class ConflictError extends AppError {
  constructor(message: string, details: unknown = null) {
    super(409, 'CONFLICT', message, details);
  }
}

export class CorsForbiddenError extends AppError {
  constructor(message: string, details: unknown = null) {
    super(403, 'CORS_FORBIDDEN', message, details);
  }
}

export class ServiceUnavailableError extends AppError {
  constructor(message: string, details: unknown = null) {
    super(503, 'SERVICE_UNAVAILABLE', message, details);
  }
}

export function formatErrorResponse(
  code: ApiErrorCode,
  message: string,
  details: unknown = null,
): ApiErrorPayload {
  return {
    error: {
      code,
      message,
      details,
    },
  };
}
