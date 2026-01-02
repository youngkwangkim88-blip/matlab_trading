"""Backtest runner utilities for Step-1."""

from __future__ import annotations

from dataclasses import asdict
from pathlib import Path
from typing import Optional

import pandas as pd

from .config import BacktestConfig, CostConfig, IndicatorConfig, StrategyConfig
from .data_manager import OhlcvDataManager
from .data_provider import CsvProvider, OhlcvFrame, YfinanceProvider
from .trader import TickerTraderStep1


# ---------------------------------------------------------------------------
# Backward-compatible aliases
#
# Earlier script versions imported `run_yfinance()` from this module.
# Step-1 v3 renamed the function to `run_step1_from_yfinance()`.
# Keep an alias so existing scripts (e.g., compare_to_reference.py) work.
# ---------------------------------------------------------------------------


def run_yfinance(*args, **kwargs):
    """Alias for :func:`run_step1_from_yfinance` (kept for compatibility)."""
    return run_step1_from_yfinance(*args, **kwargs)


def run_step1_from_yfinance(
    symbol: str,
    start: str,
    end: str,
    interval: str = "1d",
    output_dir: str | Path = "outputs",
    ind_cfg: IndicatorConfig = IndicatorConfig(),
    strat_cfg: StrategyConfig = StrategyConfig(),
    cost_cfg: CostConfig = CostConfig(),
    auto_adjust: bool = False,
    include_warmup: bool = True,
) -> dict[str, Path]:
    """Convenience runner using yfinance."""
    # Mirror MATLAB DM behavior: when a backtest window is specified, include
    # extra warmup bars before `start` so indicators (esp. long-term trend)
    # are computed on a longer history, then trim outputs back to the window.
    start_dt = pd.to_datetime(start)
    end_dt = pd.to_datetime(end)

    warmup_start = start_dt
    if include_warmup:
        warmup_bars = max(
            int(ind_cfg.sma_long_term),
            int(ind_cfg.atr_window),
            int(ind_cfg.sma_slow),
            int(ind_cfg.macd_slow + 3 * ind_cfg.macd_signal),
            250,
        )
        # calendar days approximation (weekends/holidays) for daily bars
        warmup_start = start_dt - pd.Timedelta(days=int(warmup_bars * 2))

    frame = YfinanceProvider().fetch(
        symbol=symbol,
        start=str(warmup_start.date()),
        end=str(end_dt.date()),
        interval=interval,
        auto_adjust=auto_adjust,
    )
    return _run_core(frame, output_dir, ind_cfg, strat_cfg, cost_cfg, start_dt=start_dt, end_dt=end_dt)


def run_step1_from_csv(
    csv_path: str | Path,
    symbol: str,
    output_dir: str | Path = "outputs",
    ind_cfg: IndicatorConfig = IndicatorConfig(),
    strat_cfg: StrategyConfig = StrategyConfig(),
    cost_cfg: CostConfig = CostConfig(),
) -> dict[str, Path]:
    frame = CsvProvider().fetch(csv_path=csv_path, symbol=symbol)
    return _run_core(frame, output_dir, ind_cfg, strat_cfg, cost_cfg)


def _run_core(
    frame: OhlcvFrame,
    output_dir: str | Path,
    ind_cfg: IndicatorConfig,
    strat_cfg: StrategyConfig,
    cost_cfg: CostConfig,
    start_dt: Optional[pd.Timestamp] = None,
    end_dt: Optional[pd.Timestamp] = None,
) -> dict[str, Path]:
    out_dir = Path(output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    dm = OhlcvDataManager(frame, ind_cfg)
    bt_cfg = BacktestConfig(symbol=frame.symbol, initial_capital=1_000_000_000.0, valuation_mode="CLOSE", initial_equity=1.0)

    trader = TickerTraderStep1(dm=dm, strat_cfg=strat_cfg, cost_cfg=cost_cfg, bt_cfg=bt_cfg)
    trader.run_full_backtest()

    eq = pd.DataFrame(trader.equity_curve, columns=["Date", "Equity"]).set_index("Date")

    # Trim to requested window (exclude indicator warmup segment).
    if start_dt is not None and end_dt is not None:
        eq = eq.loc[(eq.index >= start_dt) & (eq.index <= end_dt)]
    trades = pd.DataFrame([asdict(x) for x in trader.trade_log])
    if start_dt is not None and end_dt is not None and not trades.empty:
        trades["timestamp"] = pd.to_datetime(trades["timestamp"])
        trades = trades.loc[(trades["timestamp"] >= start_dt) & (trades["timestamp"] <= end_dt)]

    eq_path = out_dir / f"equity_{frame.symbol.replace('.', '_')}.csv"
    tr_path = out_dir / f"trades_{frame.symbol.replace('.', '_')}.csv"
    eq.to_csv(eq_path, encoding="utf-8")
    trades.to_csv(tr_path, index=False, encoding="utf-8")

    return {"equity": eq_path, "trades": tr_path}
