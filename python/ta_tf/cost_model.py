"""KRX-like cost model for Step-1 prototype."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from math import exp

from .config import CostConfig


@dataclass(frozen=True)
class CostBreakdown:
    fee_rate: float
    tax_rate: float


class KRXCostModel:
    """Costs:
    - commission: applied on any transaction (entry/exit/add)
    - STT (stock transaction tax): applied on *sells*
    - short borrow: applied daily while short
    """

    def __init__(self, cfg: CostConfig):
        self.cfg = cfg

    def transaction_cost_rates(self, side: str) -> CostBreakdown:
        """Return (fee_rate, tax_rate) for a transaction side."""
        fee = float(self.cfg.commission_rate)
        tax = 0.0
        if side.upper() == "SELL":
            tax = float(self.cfg.stt_rate)
        return CostBreakdown(fee_rate=fee, tax_rate=tax)

    def short_borrow_daily_rate(self) -> float:
        """Daily borrow cost rate.

        Default uses calendar-day convention (annual/365) via
        ``CostConfig.short_borrow_day_count``.
        """
        day_count = float(getattr(self.cfg, "short_borrow_day_count", 365))
        if day_count <= 0:
            day_count = 365.0
        return float(self.cfg.short_borrow_annual_rate) / day_count
