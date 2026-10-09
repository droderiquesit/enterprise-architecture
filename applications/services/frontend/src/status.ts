import type { ApiClient, Order } from './api';

export const TERMINAL_STATUSES = new Set(['Fulfilled', 'Failed']);

export interface TimelineEntry {
  status: string;
  at: string;
}

export interface PollOptions {
  intervalMs?: number;
  maxIntervalMs?: number;
  timeoutMs?: number;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
  signal?: { cancelled: boolean };
}

/**
 * Poll GET /api/orders/{id} until the order reaches Fulfilled or Failed (or timeout/cancel).
 * Calls onUpdate whenever the status changes; the interval backs off x1.5 up to maxIntervalMs.
 */
export async function pollOrderStatus(
  api: Pick<ApiClient, 'order'>,
  id: string,
  onUpdate: (order: Order, timeline: TimelineEntry[]) => void,
  opts: PollOptions = {},
): Promise<{ order: Order | null; timeline: TimelineEntry[]; outcome: 'terminal' | 'timeout' | 'cancelled' }> {
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const now = opts.now ?? (() => Date.now());
  const deadline = now() + (opts.timeoutMs ?? 120_000);
  let interval = opts.intervalMs ?? 1000;
  const timeline: TimelineEntry[] = [];
  let last: Order | null = null;
  while (now() < deadline) {
    if (opts.signal?.cancelled) return { order: last, timeline, outcome: 'cancelled' };
    try {
      const order = await api.order(id);
      last = order;
      if (timeline.length === 0 || timeline[timeline.length - 1].status !== order.status) {
        timeline.push({ status: order.status, at: new Date(now()).toISOString() });
        onUpdate(order, [...timeline]);
      }
      if (TERMINAL_STATUSES.has(order.status)) return { order, timeline, outcome: 'terminal' };
    } catch {
      // transient errors are tolerated; the deadline bounds the loop
    }
    await sleep(interval);
    interval = Math.min(Math.round(interval * 1.5), opts.maxIntervalMs ?? 5000);
  }
  return { order: last, timeline, outcome: 'timeout' };
}
