import { useEffect, useState } from 'react';
import type { ApiClient, Product } from '../api';
import { ApiError, newIdempotencyKey } from '../api';

interface Props {
  api: ApiClient;
  customerRef: string;
  onOrdered: (orderId: string) => void;
}

export function ProductsPage({ api, customerRef, onOrdered }: Props) {
  const [products, setProducts] = useState<Product[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<Product | null>(null);
  const [quantity, setQuantity] = useState(1);
  const [submitting, setSubmitting] = useState(false);
  // One key per order attempt: a retried submit of the same form re-uses it (server de-duplicates).
  const [idemKey, setIdemKey] = useState(newIdempotencyKey());

  useEffect(() => {
    let alive = true;
    api
      .products()
      .then((p) => alive && setProducts(p))
      .catch((e: unknown) => alive && setError(e instanceof ApiError ? e.message : 'failed to load products'));
    return () => {
      alive = false;
    };
  }, [api]);

  async function placeOrder() {
    if (!selected) return;
    setSubmitting(true);
    setError(null);
    try {
      const order = await api.createOrder(selected.sku, quantity, customerRef, idemKey);
      setIdemKey(newIdempotencyKey());
      onOrdered(order.id);
    } catch (e) {
      setError(e instanceof ApiError ? `Order failed: ${e.message}` : 'Order failed');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <section aria-labelledby="products-title">
      <h2 id="products-title">Products</h2>
      {error && (
        <p role="alert" className="error" data-testid="error">
          {error}
        </p>
      )}
      {products === null && !error && <p data-testid="loading">Loading products…</p>}
      {products && (
        <table data-testid="product-list" className="products">
          <thead>
            <tr>
              <th scope="col">SKU</th>
              <th scope="col">Name</th>
              <th scope="col">Price</th>
              <th scope="col" aria-label="Actions" />
            </tr>
          </thead>
          <tbody>
            {products.map((p) => (
              <tr key={p.sku} data-testid={`product-row-${p.sku}`}>
                <td>{p.sku}</td>
                <td>{p.name}</td>
                <td>
                  {(p.unit_price ?? 0).toFixed(2)} {p.currency ?? 'USD'}
                </td>
                <td>
                  <button type="button" data-testid={`order-${p.sku}`} onClick={() => setSelected(p)}>
                    Order
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {selected && (
        <form
          className="order-form"
          data-testid="order-form"
          onSubmit={(e) => {
            e.preventDefault();
            void placeOrder();
          }}
        >
          <h3>Create order</h3>
          <p>
            {selected.name} ({selected.sku})
          </p>
          <label>
            Quantity{' '}
            <input
              data-testid="quantity-input"
              type="number"
              min={1}
              max={10}
              value={quantity}
              onChange={(e) => setQuantity(Math.max(1, Math.min(10, Number(e.target.value) || 1)))}
            />
          </label>
          <button type="submit" data-testid="place-order" disabled={submitting}>
            {submitting ? 'Placing…' : 'Place order'}
          </button>
        </form>
      )}
    </section>
  );
}
