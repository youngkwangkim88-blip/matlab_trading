"""Data manager: computes indicators and provides prev-context.

This mimics `ticker_data_manager.get_ctx_prev(t)` in the MATLAB code.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Optional

import numpy as np
import pandas as pd

from .config import IndicatorConfig
from .data_provider import OhlcvFrame
from .indicators import atr as atr_func, macd as macd_func
from .types import PrevContext


class OhlcvDataManager:
    """Holds OHLCV and indicator series for a single symbol."""

    def __init__(self, frame: OhlcvFrame, ind_cfg: IndicatorConfig):
        self.symbol = frame.symbol
        self.df = frame.df.copy()
        self.ind_cfg = ind_cfg

        self._compute_indicators()

    def _compute_indicators(self) -> None:
        df = self.df
        cfg = self.ind_cfg

        close = df["Close"]

        # MATLAB prototype uses movmean(x, [N-1 0], "omitnan"), which yields
        # partial-window values from the first bar. Mirror that with min_periods=1.
        self.df["smaWeek"] = close.rolling(cfg.sma_week, min_periods=1).mean()
        self.df["smaFast"] = close.rolling(cfg.sma_fast, min_periods=1).mean()
        self.df["smaSlow"] = close.rolling(cfg.sma_slow, min_periods=1).mean()
        self.df["smaLongTerm"] = close.rolling(cfg.sma_long_term, min_periods=1).mean()
        self.df["atr"] = atr_func(df, cfg.atr_window)

        # long-term trend: compare smaLongTerm(t) with smaLongTerm(t - lookback)
        lb = cfg.long_trend_lookback
        sma_lt = self.df["smaLongTerm"]
        diff = sma_lt - sma_lt.shift(lb)
        trend = np.where(diff > 0, 1, np.where(diff < 0, -1, 0)).astype(np.int8)
        # invalidate where either side is nan
        invalid = (~np.isfinite(sma_lt.to_numpy())) | (~np.isfinite(sma_lt.shift(lb).to_numpy()))
        trend[invalid] = 0
        self.df["longTermTrend"] = trend

        macd_line, macd_sig, macd_hist = macd_func(df, cfg.macd_fast, cfg.macd_slow, cfg.macd_signal)
        self.df["macdLine"] = macd_line
        self.df["macdSignal"] = macd_sig
        self.df["macdHist"] = macd_hist

        # ensure strictly increasing index
        self.df = self.df[~self.df.index.duplicated(keep="last")].sort_index()

    def __len__(self) -> int:
        return int(len(self.df))

    def get_bar_timestamp(self, i: int) -> datetime:
        return self.df.index[i].to_pydatetime()

    def get_ohlc(self, i: int) -> tuple[float, float, float, float]:
        row = self.df.iloc[i]
        return float(row["Open"]), float(row["High"]), float(row["Low"]), float(row["Close"])

    def get_open(self, i: int) -> float:
        return float(self.df["Open"].iloc[i])

    def get_prev_context(self, i: int) -> PrevContext:
        """Return indicator context based on previous bar (i-1)."""
        if i < 2 or i >= len(self.df):
            # need i-1 and also next bar for mark-to-market in the trader loop
            ts = self.get_bar_timestamp(min(max(i, 0), len(self.df) - 1))
            return PrevContext(
                valid=False,
                timestamp=ts,
                close_prev=float("nan"),
                sma_week_prev=float("nan"),
                sma_fast_prev=float("nan"),
                sma_slow_prev=float("nan"),
                atr_prev=float("nan"),
                long_term_trend_prev=0,
                macd_line_prev=float("nan"),
                macd_signal_prev=float("nan"),
                macd_hist_prev=float("nan"),
            )

        row_prev = self.df.iloc[i - 1]
        ts = self.get_bar_timestamp(i)

        def _scalar(x):
            """Convert a value to a scalar float.

            Defensive against accidental duplicate columns (x may be a Series).
            """
            if isinstance(x, pd.Series):
                # take first value deterministically
                x = x.iloc[0] if len(x) else float("nan")
            return float(x) if pd.notna(x) else float("nan")

        valid = True
        for key in ["smaWeek", "smaFast", "smaSlow"]:
            v = row_prev[key]
            if isinstance(v, pd.Series):
                v = v.iloc[0] if len(v) else float("nan")
            if not np.isfinite(v):
                valid = False
                break

        return PrevContext(
            valid=valid,
            timestamp=ts,
            close_prev=_scalar(row_prev["Close"]),
            sma_week_prev=_scalar(row_prev["smaWeek"]),
            sma_fast_prev=_scalar(row_prev["smaFast"]),
            sma_slow_prev=_scalar(row_prev["smaSlow"]),
            atr_prev=_scalar(row_prev["atr"]),
            long_term_trend_prev=int(row_prev["longTermTrend"]),
            macd_line_prev=_scalar(row_prev["macdLine"]),
            macd_signal_prev=_scalar(row_prev["macdSignal"]),
            macd_hist_prev=_scalar(row_prev["macdHist"]),
        )
