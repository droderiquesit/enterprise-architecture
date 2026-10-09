import { useEffect, useState } from 'react';
import type { Adapter, ApiClient, RoundtripResult } from '../api';
import { ApiError } from '../api';

export function AdaptersPanel({ api }: { api: ApiClient }) {
  const [adapters, setAdapters] = useState<Adapter[] | null>(null);
  const [results, setResults] = useState<Record<string, RoundtripResult | { error: string }>>({});
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api
      .adapters()
      .then(setAdapters)
      .catch((e: unknown) => setError(e instanceof ApiError ? e.message : 'failed to load adapters'));
  }, [api]);

  async function run(adapter: Adapter) {
    setResults((r) => ({ ...r, [adapter.family]: { error: 'running…' } }));
    try {
      const res = await api.roundtrip(adapter);
      setResults((r) => ({ ...r, [adapter.family]: res }));
    } catch (e) {
      setResults((r) => ({ ...r, [adapter.family]: { error: e instanceof ApiError ? e.message : 'failed' } }));
    }
  }

  return (
    <section aria-labelledby="adapters-title">
      <h2 id="adapters-title">Database adapters</h2>
      {error && <p role="alert" className="error">{error}</p>}
      {adapters && adapters.length === 0 && <p>No adapters configured for this environment.</p>}
      <ul className="adapters" data-testid="adapter-list">
        {(adapters ?? []).map((a) => {
          const r = results[a.family];
          return (
            <li key={a.family} data-testid={`adapter-${a.family}`}>
              <button type="button" onClick={() => void run(a)}>
                Roundtrip {a.family}
              </button>{' '}
              {r && 'ok' in r && (
                <span data-testid={`adapter-result-${a.family}`} className={r.ok ? 'ok' : 'error'}>
                  {r.ok ? 'ok' : `failed: ${r.error ?? ''}`}{' '}
                  {r.timings_ms &&
                    Object.entries(r.timings_ms)
                      .map(([k, v]) => `${k} ${v}ms`)
                      .join(' · ')}
                </span>
              )}
              {r && !('ok' in r) && <span className="muted">{r.error}</span>}
            </li>
          );
        })}
      </ul>
    </section>
  );
}
