import { describe, expect, it } from 'vitest';
import type { Order } from './api';
import { pollOrderStatus } from './status';

function clock() {
  let t = 0;
  return { now: () => t, sleep: async (ms: number) => void (t += ms) };
}

describe('pollOrderStatus', () => {
  it('records each status change until terminal', async () => {
    const seq = ['Pending', 'Pending', 'Reserved', 'Charged', 'Fulfilled'];
    const api = { order: async (id: string): Promise<Order> => ({ id, sku: 'SKU-0001', quantity: 1, status: seq.shift() ?? 'Fulfilled' }) };
    const updates: string[] = [];
    const c = clock();
    const r = await pollOrderStatus(api, 'o-1', (o) => updates.push(o.status), { ...c, intervalMs: 100 });
    expect(r.outcome).toBe('terminal');
    expect(r.timeline.map((t) => t.status)).toEqual(['Pending', 'Reserved', 'Charged', 'Fulfilled']);
    expect(updates).toEqual(['Pending', 'Reserved', 'Charged', 'Fulfilled']);
  });

  it('stops on Failed, tolerates transient errors, and times out', async () => {
    let n = 0;
    const api = {
      order: async (id: string): Promise<Order> => {
        n += 1;
        if (n === 1) throw new Error('503');
        return { id, sku: 'S', quantity: 1, status: n < 3 ? 'Pending' : 'Failed' };
      },
    };
    const r = await pollOrderStatus(api, 'o-2', () => {}, { ...clock(), intervalMs: 10 });
    expect(r.outcome).toBe('terminal');
    expect(r.order?.status).toBe('Failed');
    const stuck = { order: async (id: string): Promise<Order> => ({ id, sku: 'S', quantity: 1, status: 'Pending' }) };
    const t = await pollOrderStatus(stuck, 'o-3', () => {}, { ...clock(), intervalMs: 1000, maxIntervalMs: 4000, timeoutMs: 20_000 });
    expect(t.outcome).toBe('timeout');
  });

  it('can be cancelled', async () => {
    const signal = { cancelled: true };
    const api = { order: async (): Promise<Order> => ({ id: 'x', sku: 'S', quantity: 1, status: 'Pending' }) };
    expect((await pollOrderStatus(api, 'x', () => {}, { ...clock(), signal })).outcome).toBe('cancelled');
  });
});
