"""Performance metrics."""

from __future__ import annotations

import numpy as np
import pandas as pd


def max_drawdown(equity: pd.Series) -> float:
    """Maximum drawdown (as positive fraction)."""
    x = equity.astype(float).to_numpy()
    if len(x) == 0:
        return float("nan")
    peak = np.maximum.accumulate(x)
    dd = 1.0 - (x / np.maximum(peak, np.finfo(float).tiny))
    return float(np.nanmax(dd))


def cagr(equity: pd.Series) -> float:
    """CAGR from first to last point using calendar days."""
    if len(equity) < 2:
        return float("nan")
    start = equity.index[0]
    end = equity.index[-1]
    days = (end.date() - start.date()).days
    if days <= 0:
        return float("nan")
    total = float(equity.iloc[-1] / equity.iloc[0])
    return total ** (365.0 / days) - 1.0
