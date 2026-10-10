"""Deterministic synthetic catalog: SKU-0001..SKU-0020 (same data on every run/environment)."""

from __future__ import annotations

from decimal import Decimal

from .models import ProductIn

_ADJECTIVES = ["Classic", "Compact", "Deluxe", "Eco", "Ultra"]
_NOUNS = ["Widget", "Gadget", "Sprocket", "Gizmo"]
_CATEGORIES = ["hardware", "accessories", "tools", "spares"]


def seed_products(count: int = 20) -> list[ProductIn]:
    items = []
    for i in range(1, count + 1):
        adjective = _ADJECTIVES[(i - 1) % len(_ADJECTIVES)]
        noun = _NOUNS[(i - 1) // len(_ADJECTIVES) % len(_NOUNS)]
        price = (Decimal(5) + (Decimal(i) * Decimal("7.35")) % Decimal(95)).quantize(Decimal("0.01"))
        items.append(
            ProductIn(
                sku=f"SKU-{i:04d}",
                name=f"{adjective} {noun} {i}",
                description=f"Synthetic product {i} for the Enterprise Hello lab.",
                unit_price=price,
                currency="USD",
                category=_CATEGORIES[(i - 1) % len(_CATEGORIES)],
                active=True,
            )
        )
    return items
