import { useEffect, useState } from 'react';
import type { ApiClient, Order } from '../api';
import type { TimelineEntry } from '../status';
import { pollOrderStatus } from '../status';

export function OrderStatus({ api, orderId, timeoutMs = 120_000 }: { api: ApiClient; orderId: string; timeoutMs?: number }) {
  const [order, setOrder] = useState<Order | null>(null);
  const [timeline, setTimeline] = useState<TimelineEntry[]>([]);
  const [outcome, setOutcome] = useState<string>('polling');

  useEffect(() => {
    const signal = { cancelled: false };
    setOrder(null);
    setTimeline([]);
    setOutcome('polling');
    pollOrderStatus(
      api,
      orderId,
      (o, t) => {
        setOrder(o);
        setTimeline(t);
      },
      { signal, timeoutMs },
    ).then((r) => !signal.cancelled && setOutcome(r.outcome));
    return () => {
      signal.cancelled = true;
    };
  }, [api, orderId, timeoutMs]);

  const status = order?.status ?? 'Unknown';
  return (
    <section aria-labelledby="order-title">
      <h2 id="order-title">Order {orderId}</h2>
      <p>
        Status:{' '}
        <strong data-testid="order-status" data-status={status} className={`status status-${status.toLowerCase()}`}>
          {status}
        </strong>
        {outcome === 'polling' && <span className="muted"> (updating…)</span>}
        {outcome === 'timeout' && <span className="muted"> (stopped waiting)</span>}
      </p>
      {order && (
        <p className="muted">
          {order.quantity} × {order.sku}
          {order.amount !== undefined && ` = ${Number(order.amount).toFixed(2)}`}
        </p>
      )}
      <ol className="timeline" data-testid="timeline">
        {timeline.map((t) => (
          <li key={`${t.status}-${t.at}`} data-testid="timeline-item">
            <span className="status">{t.status}</span> <time dateTime={t.at}>{new Date(t.at).toLocaleTimeString()}</time>
          </li>
        ))}
      </ol>
      <a href="#/">Back to products</a>
    </section>
  );
}
