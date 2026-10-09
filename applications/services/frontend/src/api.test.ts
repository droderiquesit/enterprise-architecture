import { describe, expect, it } from 'vitest';
import { ApiClient, ApiError } from './api';

type Call = { url: string; init: RequestInit };

function fakeFetch(responses: (Response | Error)[]) {
  const calls: Call[] = [];
  const impl = (async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    const next = responses.shift();
    if (!next) throw new Error('no more responses');
    if (next instanceof Error) throw next;
    return next;
  }) as unknown as typeof fetch;
  return { impl, calls };
}

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
const noSleep = async () => {};

describe('ApiClient', () => {
  it('lists products from {items} and plain arrays', async () => {
    const f = fakeFetch([json({ items: [{ sku: 'SKU-0001', name: 'A', unit_price: 1 }], count: 1 }), json([{ sku: 'SKU-0002', name: 'B', unit_price: 2 }])]);
    const api = new ApiClient({ baseUrl: 'https://api.example.com/', fetchImpl: f.impl, sleep: noSleep });
    expect((await api.products())[0].sku).toBe('SKU-0001');
    expect((await api.products())[0].sku).toBe('SKU-0002');
    expect(f.calls[0].url).toBe('https://api.example.com/api/catalog/products');
  });

  it('creates orders with Idempotency-Key and retries the same key on 503', async () => {
    const f = fakeFetch([json({ title: 'busy' }, 503), json({ order: { id: 'o-1', sku: 'SKU-0001', quantity: 2, status: 'Pending' } }, 202)]);
    const api = new ApiClient({ baseUrl: 'https://api', fetchImpl: f.impl, sleep: noSleep });
    const order = await api.createOrder('SKU-0001', 2, 'cust-1', 'key-123');
    expect(order.id).toBe('o-1');
    expect(f.calls).toHaveLength(2);
    for (const c of f.calls) expect((c.init.headers as Record<string, string>)['Idempotency-Key']).toBe('key-123');
    expect(JSON.parse(String(f.calls[0].init.body))).toEqual({ sku: 'SKU-0001', quantity: 2, customer_ref: 'cust-1' });
  });

  it('accepts order_id and raises problem details', async () => {
    const f = fakeFetch([json({ order_id: 'x9', status: 'Pending' }), json({ title: 'Not Found', detail: 'order not found' }, 404)]);
    const api = new ApiClient({ baseUrl: 'https://api', fetchImpl: f.impl, sleep: noSleep });
    expect((await api.order('x9')).id).toBe('x9');
    await expect(api.order('missing')).rejects.toMatchObject({ status: 404, message: 'order not found' });
  });

  it('bounds GET retries on network errors', async () => {
    const f = fakeFetch([new TypeError('net'), new TypeError('net'), new TypeError('net')]);
    const api = new ApiClient({ baseUrl: 'https://api', fetchImpl: f.impl, sleep: noSleep, retries: 2 });
    await expect(api.products()).rejects.toBeInstanceOf(ApiError);
    expect(f.calls).toHaveLength(3);
  });

  it('roundtrips adapters through the BFF-provided roundtrip_path', async () => {
    const f = fakeFetch([json([{ family: 'mysql', roundtrip_path: '/api/adapters/mysql/roundtrip' }]), json({ family: 'mysql', ok: true })]);
    const api = new ApiClient({ baseUrl: 'https://api', fetchImpl: f.impl, sleep: noSleep });
    const [a] = await api.adapters();
    expect((await api.roundtrip(a)).ok).toBe(true);
    expect(f.calls[1].url).toBe('https://api/api/adapters/mysql/roundtrip');
    expect(f.calls[1].init.method).toBe('POST');
  });
});
