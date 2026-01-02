"""Indicator computation utilities.

We compute indicators on the CLOSE series and use **previous-bar** values
to avoid lookahead.
"""

from __future__ import annotations

import numpy as np
import pandas as pd


def ema(series: pd.Series, span: int) -> pd.Series:
    """Exponential moving average with a stable definition.

    Uses pandas ewm with adjust=False (recursive form).
    """
    if span <= 0:
        raise ValueError("span must be positive")
    # MATLAB prototype initializes EMA at the first finite sample and then
    # proceeds recursively without a long "warm-up" NaN segment.
    return series.ewm(span=span, adjust=False, min_periods=1).mean()


def atr(df: pd.DataFrame, window: int) -> pd.Series:
    """Average True Range (simple moving average of TR)."""
    if window <= 0:
        raise ValueError("window must be positive")
    high = df["High"].astype(float)
    low = df["Low"].astype(float)
    close = df["Close"].astype(float)
    prev_close = close.shift(1)
    tr = pd.concat(
        [
            (high - low).abs(),
            (high - prev_close).abs(),
            (low - prev_close).abs(),
        ],
        axis=1,
    ).max(axis=1)
    # MATLAB prototype uses movmean(TR, [window-1 0], 'omitnan'), which
    # yields values from the beginning using a partial window.
    return tr.rolling(window=window, min_periods=1).mean()


def macd(df: pd.DataFrame, fast: int, slow: int, signal: int) -> tuple[pd.Series, pd.Series, pd.Series]:
    """MACD line, signal line, and histogram."""
    close = df["Close"].astype(float)
    macd_line = ema(close, fast) - ema(close, slow)
    signal_line = ema(macd_line, signal)
    hist = macd_line - signal_line
    return macd_line, signal_line, hist
