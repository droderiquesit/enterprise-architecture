import { describe, expect, it } from 'vitest';
import { ConfigError, deriveTracingOrigins, loadConfig, parseConfig, tracingMatchers } from './config';

const rum = { applicationId: 'app-1', clientToken: 'pub123', site: 'datadoghq.eu', sessionSampleRate: 50 };

describe('parseConfig', () => {
  it('applies defaults and omits rum when missing', () => {
    const c = parseConfig({ apiBaseUrl: 'https://api.example.com/' });
    expect(c).toEqual({ env: 'local', service: 'hello-frontend', version: '0.0.0-dev', apiBaseUrl: 'https://api.example.com' });
    expect(c.rum).toBeUndefined();
  });

  it('parses rum and forces safe defaults', () => {
    const c = parseConfig({ env: 'dev', version: '1.2.3', apiBaseUrl: 'https://api.example.com', rum });
    expect(c.rum).toMatchObject({
      applicationId: 'app-1', site: 'datadoghq.eu', sessionSampleRate: 50, sessionReplaySampleRate: 0, traceSampleRate: 100,
      trackUserInteractions: true, defaultPrivacyLevel: 'mask-user-input', allowedTracingUrls: ['https://api.example.com'],
    });
  });

  it('rejects secrets and invalid values', () => {
    expect(() => parseConfig({ apiBaseUrl: 'https://a.b', rum: { ...rum, clientToken: 'abcdef0123456789abcdef0123456789' } })).toThrow(/public client token/);
    expect(() => parseConfig({ apiBaseUrl: 'https://a.b', rum: { ...rum, site: 'evil.com' } })).toThrow(ConfigError);
    expect(() => parseConfig({ apiBaseUrl: 'https://a.b', rum: { ...rum, sessionSampleRate: 101 } })).toThrow(/between 0 and 100/);
    expect(() => parseConfig({ apiBaseUrl: 'https://a.b', rum: { ...rum, applicationId: '' } })).toThrow(/applicationId/);
    expect(() => parseConfig('nope')).toThrow(ConfigError);
  });
});

describe('allowedTracingUrls derivation', () => {
  it('defaults to the API origin', () => {
    expect(deriveTracingOrigins('https://api.example.com/base', undefined)).toEqual(['https://api.example.com']);
    expect(deriveTracingOrigins('/api', undefined, 'https://www.example.com')).toEqual(['https://www.example.com']);
  });

  it('accepts origins only and dedupes', () => {
    expect(deriveTracingOrigins('https://a.example.com', ['https://a.example.com/', 'https://b.example.com:8443', 'https://a.example.com'])).toEqual([
      'https://a.example.com', 'https://b.example.com:8443',
    ]);
    expect(() => deriveTracingOrigins('https://a.example.com', ['https://a.example.com/api'])).toThrow(/origins only/);
    expect(() => deriveTracingOrigins('https://a.example.com', ['*.example.com'])).toThrow(ConfigError);
    expect(() => deriveTracingOrigins('https://a.example.com', ['http://insecure.example.com'])).toThrow(/localhost/);
    expect(deriveTracingOrigins('http://localhost:8080', undefined)).toEqual(['http://localhost:8080']);
  });

  it('matchers use exact origin equality (no prefix tricks) and tracecontext only', () => {
    const [m] = tracingMatchers(['https://api.example.com']);
    expect(m.propagatorTypes).toEqual(['tracecontext']);
    expect(m.match('https://api.example.com/api/orders')).toBe(true);
    expect(m.match('https://api.example.com')).toBe(true);
    expect(m.match('https://api.example.com.evil.net/api')).toBe(false);
    expect(m.match('http://api.example.com/api')).toBe(false);
    expect(m.match('https://browser-intake-datadoghq.com/api/v2/rum')).toBe(false);
  });
});

describe('loadConfig', () => {
  it('fetches /config.json without cache', async () => {
    let seen: RequestInit | undefined;
    const fake = (async (_url: string, init?: RequestInit) => {
      seen = init;
      return new Response(JSON.stringify({ apiBaseUrl: 'https://x.example.com' }), { status: 200 });
    }) as unknown as typeof fetch;
    const c = await loadConfig(fake);
    expect(c.apiBaseUrl).toBe('https://x.example.com');
    expect(seen?.cache).toBe('no-store');
    const failing = (async () => new Response('', { status: 404 })) as unknown as typeof fetch;
    await expect(loadConfig(failing)).rejects.toThrow(/HTTP 404/);
  });
});
