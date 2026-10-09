/**
 * Runtime configuration loaded from /config.json BEFORE the app (and RUM) starts.
 * The same static bundle is promoted across environments; only config.json differs.
 * Never contains Datadog API/application keys - only the public RUM client token.
 */

export const DATADOG_SITES = [
  'datadoghq.com',
  'us3.datadoghq.com',
  'us5.datadoghq.com',
  'datadoghq.eu',
  'ap1.datadoghq.com',
  'ap2.datadoghq.com',
  'ddog-gov.com',
] as const;

export type PrivacyLevel = 'mask-user-input' | 'mask' | 'allow';

export interface RumSettings {
  applicationId: string;
  clientToken: string;
  site: string;
  sessionSampleRate: number;
  sessionReplaySampleRate: number;
  traceSampleRate: number;
  trackUserInteractions: boolean;
  defaultPrivacyLevel: PrivacyLevel;
  allowedTracingUrls: string[]; // first-party API origins (scheme://host[:port])
}

export interface AppConfig {
  env: string;
  service: string;
  version: string;
  apiBaseUrl: string;
  rum?: RumSettings;
}

export class ConfigError extends Error {}

function str(value: unknown, name: string, fallback?: string): string {
  if (typeof value === 'string' && value.trim() !== '') return value.trim();
  if (fallback !== undefined) return fallback;
  throw new ConfigError(`config.${name} must be a non-empty string`);
}

function rate(value: unknown, name: string, fallback: number): number {
  if (value === undefined || value === null) return fallback;
  if (typeof value !== 'number' || Number.isNaN(value) || value < 0 || value > 100) {
    throw new ConfigError(`config.${name} must be a number between 0 and 100`);
  }
  return value;
}

/** Normalise an origin; only http(s) origins without path/query/credentials are accepted. */
export function toOrigin(value: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new ConfigError(`invalid URL: ${value}`);
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') throw new ConfigError(`unsupported scheme: ${value}`);
  if (url.username || url.password) throw new ConfigError(`credentials not allowed in URL: ${value}`);
  if (url.protocol === 'http:' && !['localhost', '127.0.0.1'].includes(url.hostname)) {
    throw new ConfigError(`plain http is only allowed for localhost: ${value}`);
  }
  return url.origin;
}

/**
 * Origins whose requests may carry W3C trace context. Defaults to the API origin. Each configured entry must
 * be an origin (a path, wildcard or query is rejected) so third-party hosts can never be matched by prefix.
 */
export function deriveTracingOrigins(apiBaseUrl: string, configured: unknown, pageOrigin?: string): string[] {
  const apiOrigin = toOrigin(new URL(apiBaseUrl, pageOrigin ?? 'http://localhost').toString());
  const entries = Array.isArray(configured) && configured.length > 0 ? configured : [apiOrigin];
  const origins = entries.map((entry) => {
    if (typeof entry !== 'string') throw new ConfigError('rum.allowedTracingUrls entries must be strings');
    const origin = toOrigin(entry);
    const trimmed = entry.replace(/\/+$/, '');
    if (trimmed !== origin) throw new ConfigError(`rum.allowedTracingUrls must contain origins only (no path): ${entry}`);
    return origin;
  });
  return Array.from(new Set(origins));
}

/** Build RUM allowedTracingUrls matchers: exact origin match (URL origin equality), tracecontext only. */
export function tracingMatchers(origins: string[]): { match: (url: string) => boolean; propagatorTypes: ['tracecontext'] }[] {
  return origins.map((origin) => ({
    match: (url: string) => {
      try {
        return new URL(url, window.location.href).origin === origin;
      } catch {
        return false;
      }
    },
    propagatorTypes: ['tracecontext'],
  }));
}

export function parseConfig(raw: unknown, pageOrigin?: string): AppConfig {
  if (!raw || typeof raw !== 'object') throw new ConfigError('config.json must be a JSON object');
  const c = raw as Record<string, unknown>;
  const apiBaseUrl = str(c.apiBaseUrl, 'apiBaseUrl', '').replace(/\/+$/, '');
  const config: AppConfig = {
    env: str(c.env, 'env', 'local'),
    service: str(c.service, 'service', 'hello-frontend'),
    version: str(c.version, 'version', '0.0.0-dev'),
    apiBaseUrl,
  };
  if (c.rum && typeof c.rum === 'object') {
    const r = c.rum as Record<string, unknown>;
    const site = str(r.site, 'rum.site', 'datadoghq.com');
    if (!(DATADOG_SITES as readonly string[]).includes(site)) throw new ConfigError(`unsupported rum.site: ${site}`);
    const privacy = str(r.defaultPrivacyLevel, 'rum.defaultPrivacyLevel', 'mask-user-input') as PrivacyLevel;
    if (!['mask-user-input', 'mask', 'allow'].includes(privacy)) throw new ConfigError(`invalid rum.defaultPrivacyLevel: ${privacy}`);
    const base = apiBaseUrl || pageOrigin || 'http://localhost';
    config.rum = {
      applicationId: str(r.applicationId, 'rum.applicationId'),
      clientToken: str(r.clientToken, 'rum.clientToken'),
      site,
      sessionSampleRate: rate(r.sessionSampleRate, 'rum.sessionSampleRate', 100),
      sessionReplaySampleRate: rate(r.sessionReplaySampleRate, 'rum.sessionReplaySampleRate', 0),
      traceSampleRate: rate(r.traceSampleRate, 'rum.traceSampleRate', 100),
      trackUserInteractions: r.trackUserInteractions !== false,
      defaultPrivacyLevel: privacy,
      allowedTracingUrls: deriveTracingOrigins(base, r.allowedTracingUrls, pageOrigin),
    };
    if (!config.rum.clientToken.startsWith('pub')) {
      throw new ConfigError('rum.clientToken must be a public client token (pub...), never an API or application key');
    }
  }
  return config;
}

export async function loadConfig(fetchImpl: typeof fetch = fetch, url = '/config.json'): Promise<AppConfig> {
  const res = await fetchImpl(url, { cache: 'no-store', headers: { accept: 'application/json' } });
  if (!res.ok) throw new ConfigError(`failed to load ${url}: HTTP ${res.status}`);
  return parseConfig(await res.json(), typeof window !== 'undefined' ? window.location.origin : undefined);
}
