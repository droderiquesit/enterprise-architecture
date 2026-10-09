/** Small API client for hello-bff with timeouts, bounded GET retries and Idempotency-Key on creates. */

export interface Product {
  sku: string;
  name: string;
  description?: string;
  unit_price: number;
  currency?: string;
  category?: string;
}

export interface Order {
  id: string;
  sku: string;
  quantity: number;
  amount?: number;
  status: string;
  customer_ref?: string;
  created_at?: string;
  updated_at?: string;
}

export interface Adapter {
  family: string;
  url?: string;
}

export interface RoundtripResult {
  family: string;
  ok: boolean;
  timings_ms?: Record<string, number>;
  error?: string;
  cache?: string;
}

export class ApiError extends Error {
  constructor(
    public status: number,
    message: string,
    public detail?: unknown,
  ) {
    super(message);
  }
}

export interface ApiOptions {
  baseUrl: string;
  timeoutMs?: number;
  retries?: number;
  fetchImpl?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
}

const defaultSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export function newIdempotencyKey(): string {
  if (typeof crypto !== 'undefined' && 'randomUUID' in crypto) return crypto.randomUUID();
  return `${Date.now().toString(16)}-${Math.random().toString(16).slice(2)}`;
}

function asList<T>(body: unknown, ...keys: string[]): T[] {
  if (Array.isArray(body)) return body as T[];
  if (body && typeof body === 'object') {
    for (const k of keys) {
      const v = (body as Record<string, unknown>)[k];
      if (Array.isArray(v)) return v as T[];
    }
  }
  return [];
}

function normaliseOrder(raw: unknown): Order {
  const o = (raw && typeof raw === 'object' && 'order' in (raw as object) ? (raw as { order: unknown }).order : raw) as Record<string, unknown>;
  return { ...(o as unknown as Order), id: String(o.id ?? o.order_id ?? '') };
}

export class ApiClient {
  private readonly base: string;
  private readonly timeoutMs: number;
  private readonly retries: number;
  private readonly fetchImpl: typeof fetch;
  private readonly sleep: (ms: number) => Promise<void>;

  constructor(opts: ApiOptions) {
    this.base = opts.baseUrl.replace(/\/+$/, '');
    this.timeoutMs = opts.timeoutMs ?? 8000;
    this.retries = opts.retries ?? 2;
    this.fetchImpl = opts.fetchImpl ?? ((...a) => fetch(...a));
    this.sleep = opts.sleep ?? defaultSleep;
  }

  private async request<T>(method: string, path: string, body?: unknown, headers: Record<string, string> = {}): Promise<T> {
    const retryable = method === 'GET' || 'Idempotency-Key' in headers;
    let attempt = 0;
    for (;;) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), this.timeoutMs);
      try {
        const res = await this.fetchImpl(`${this.base}${path}`, {
          method,
          headers: { accept: 'application/json', ...(body !== undefined ? { 'content-type': 'application/json' } : {}), ...headers },
          body: body !== undefined ? JSON.stringify(body) : undefined,
          signal: controller.signal,
        });
        if ([429, 502, 503, 504].includes(res.status) && retryable && attempt < this.retries) {
          attempt += 1;
          await this.sleep(Math.random() * 250 * 2 ** attempt);
          continue;
        }
        const text = await res.text();
        const parsed: unknown = text ? JSON.parse(text) : undefined;
        if (!res.ok) {
          const detail = parsed as { title?: string; detail?: string } | undefined;
          throw new ApiError(res.status, detail?.detail || detail?.title || `HTTP ${res.status}`, parsed);
        }
        return parsed as T;
      } catch (err) {
        if (err instanceof ApiError) throw err;
        if (retryable && attempt < this.retries) {
          attempt += 1;
          await this.sleep(Math.random() * 250 * 2 ** attempt);
          continue;
        }
        throw new ApiError(0, err instanceof Error && err.name === 'AbortError' ? 'request timed out' : 'network error');
      } finally {
        clearTimeout(timer);
      }
    }
  }

  async products(): Promise<Product[]> {
    return asList<Product>(await this.request('GET', '/api/catalog/products'), 'items', 'products');
  }

  async createOrder(sku: string, quantity: number, customerRef: string, idempotencyKey = newIdempotencyKey()): Promise<Order> {
    const body = await this.request<unknown>('POST', '/api/orders', { sku, quantity, customer_ref: customerRef }, { 'Idempotency-Key': idempotencyKey });
    return normaliseOrder(body);
  }

  async order(id: string): Promise<Order> {
    return normaliseOrder(await this.request<unknown>('GET', `/api/orders/${encodeURIComponent(id)}`));
  }

  async recentOrders(limit = 10): Promise<Order[]> {
    return asList<unknown>(await this.request('GET', `/api/orders?limit=${limit}`), 'items', 'orders').map(normaliseOrder);
  }

  async adapters(): Promise<Adapter[]> {
    return asList<Adapter>(await this.request('GET', '/api/adapters'), 'adapters', 'items');
  }

  async roundtrip(family: string): Promise<RoundtripResult> {
    return this.request<RoundtripResult>('POST', `/api/adapters/${encodeURIComponent(family)}/roundtrip`, {});
  }

  async version(): Promise<Record<string, string>> {
    return this.request('GET', '/api/version');
  }
}
