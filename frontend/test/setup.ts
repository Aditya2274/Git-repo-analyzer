import '@testing-library/jest-dom/vitest';

class ResizeObserverMock {
  observe(): void {}
  unobserve(): void {}
  disconnect(): void {}
}

if (typeof globalThis.ResizeObserver === 'undefined') {
  globalThis.ResizeObserver = ResizeObserverMock;
}

if (typeof URL.createObjectURL === 'undefined') {
  URL.createObjectURL = () => 'blob:mock-chart-url';
}

if (typeof URL.revokeObjectURL === 'undefined') {
  URL.revokeObjectURL = () => undefined;
}
