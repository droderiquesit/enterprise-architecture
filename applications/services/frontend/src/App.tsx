import { useEffect, useMemo, useState } from 'react';
import { ApiClient } from './api';
import { AdaptersPanel } from './components/AdaptersPanel';
import { OrderStatus } from './components/OrderStatus';
import { ProductsPage } from './components/ProductsPage';
import type { AppConfig } from './config';

function useHashRoute(): string {
  const [hash, setHash] = useState(() => window.location.hash || '#/');
  useEffect(() => {
    const onChange = () => setHash(window.location.hash || '#/');
    window.addEventListener('hashchange', onChange);
    return () => window.removeEventListener('hashchange', onChange);
  }, []);
  return hash;
}

function customerRef(): string {
  const key = 'hello.customer_ref';
  try {
    const existing = window.sessionStorage.getItem(key);
    if (existing) return existing;
    const ref = `cust-${Math.random().toString(16).slice(2, 8)}`;
    window.sessionStorage.setItem(key, ref);
    return ref;
  } catch {
    return 'cust-anonymous';
  }
}

export function App({ config, rumEnabled }: { config: AppConfig; rumEnabled: boolean }) {
  const api = useMemo(() => new ApiClient({ baseUrl: config.apiBaseUrl }), [config.apiBaseUrl]);
  const route = useHashRoute();
  const [backendVersion, setBackendVersion] = useState<string>('…');
  const ref = useMemo(customerRef, []);

  useEffect(() => {
    api
      .version()
      .then((v) => setBackendVersion(`${v.service ?? 'hello-bff'} ${v.version ?? ''}`.trim()))
      .catch(() => setBackendVersion('unavailable'));
  }, [api]);

  const orderMatch = route.match(/^#\/orders\/([A-Za-z0-9-]+)$/);
  let page;
  if (orderMatch) page = <OrderStatus api={api} orderId={orderMatch[1]} />;
  else if (route === '#/adapters') page = <AdaptersPanel api={api} />;
  else page = <ProductsPage api={api} customerRef={ref} onOrdered={(id) => (window.location.hash = `#/orders/${id}`)} />;

  return (
    <div className="app">
      <header>
        <h1>Enterprise Hello</h1>
        <nav aria-label="Main">
          <a href="#/">Products</a> <a href="#/adapters">Adapters</a>
        </nav>
      </header>
      <main>{page}</main>
      <footer data-testid="version-footer">
        {config.service} {config.version} · env {config.env} · api {backendVersion} · RUM {rumEnabled ? 'on' : 'off'}
      </footer>
    </div>
  );
}
