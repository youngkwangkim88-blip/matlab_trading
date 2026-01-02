"""Shared types for the Step-1 prototype.

The guiding principle is to keep the runtime objects small and explicit.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Optional


@dataclass(frozen=True)
class Bar:
    """OHLCV bar.

    All prices must be float (already adjusted to the desired currency scale).
    """

    timestamp: datetime
    open: float
    high: float
    low: float
    close: float
    volume: float


@dataclass(frozen=True)
class PrevContext:
    """Previous-bar indicator context used to avoid lookahead."""

    valid: bool
    timestamp: datetime
    close_prev: float

    sma_week_prev: float
    sma_fast_prev: float
    sma_slow_prev: float
    atr_prev: float
    long_term_trend_prev: int  # -1, 0, +1

    # MACD is optional. If not computed, these remain NaN.
    macd_line_prev: float
    macd_signal_prev: float
    macd_hist_prev: float


@dataclass(frozen=True)
class TradeEvent:
    """A single executed event (entry/exit/forced/stop/pyramid-add)."""

    timestamp: datetime
    symbol: str
    side: str  # 'BUY'/'SELL'
    reason: str
    price: float
    position_after: int  # -1/0/+1
    units_after: int
    fee_paid: float
    tax_paid: float

    # Optional accounting fields (added for Step-1.5+). Defaults keep backward compatibility.
    qty: int = 0  # signed shares quantity executed
    notional: float = 0.0
    cash_after: float = 0.0
    equity_after: float = 0.0  # normalized by initial_capital
