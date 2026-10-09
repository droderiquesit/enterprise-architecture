from __future__ import annotations

from datetime import datetime
from decimal import Decimal

from pydantic import BaseModel, Field

SKU_PATTERN = r"^[A-Z0-9][A-Z0-9-]{2,31}$"


class ProductIn(BaseModel):
    sku: str = Field(pattern=SKU_PATTERN)
    name: str = Field(min_length=1, max_length=200)
    description: str = Field("", max_length=2000)
    unit_price: Decimal = Field(gt=0, le=Decimal("100000"), max_digits=12, decimal_places=2)
    currency: str = Field("USD", pattern=r"^[A-Z]{3}$")
    category: str = Field("general", max_length=64)
    active: bool = True


class Product(BaseModel):
    sku: str
    name: str
    description: str
    unit_price: float
    currency: str
    category: str
    active: bool
    updated_at: datetime | None = None
