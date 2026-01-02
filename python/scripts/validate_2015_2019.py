"""Validate a saved parameter set on 2015-2019 (default) using the same engine.

By default this script reads `best_params.json` produced by
`scripts.optimize_2020_2024_single` and runs a backtest on the VALID window.

Example:
    python -m scripts.validate_2015_2019 \
      --panel_csv kospi_top100_ohlc_30y.csv --symbol 005930.KS \
      --params outputs_opt_2020_2024/best_params.json \
      --valid_start 2015-01-01 --valid_end 2019-12-31 \
      --out outputs_valid_2015_2019
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import pandas as pd

from ta_tf.config import CostConfig, IndicatorConfig, StrategyConfig
from ta_tf.data_provider import PanelCsvProvider, YfinanceProvider
from ta_tf.backtest import _run_core
from ta_tf.metrics import cagr, max_drawdown


def _parse_date(s: str) -> pd.Timestamp:
    return pd.to_datetime(s).tz_localize(None)


def _warmup_start(valid_start: pd.Timestamp, warmup_days: int) -> pd.Timestamp:
    return (valid_start - pd.Timedelta(days=int(warmup_days))).tz_localize(None)


def _load_params(path: str | Path) -> StrategyConfig:
    d = json.loads(Path(path).read_text(encoding="utf-8"))
    return StrategyConfig(**d)


def _load_frame(args, fetch_start: str, end: str):
    if args.use_yfinance:
        prov = YfinanceProvider()
        return prov.fetch(args.symbol, start=fetch_start, end=end, interval="1d")
    prov = PanelCsvProvider()
    return prov.fetch(args.panel_csv, args.symbol, start=fetch_start, end=end)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--symbol", type=str, default="005930.KS")
    p.add_argument("--valid_start", type=str, default="2015-01-01")
    p.add_argument("--valid_end", type=str, default="2019-12-31")
    p.add_argument("--warmup_days", type=int, default=900)
    p.add_argument("--params", type=str, default="outputs_opt_2020_2024/best_params.json")
    p.add_argument("--out", type=str, default="outputs_valid_2015_2019")

    # data source
    p.add_argument("--panel_csv", type=str, default=None)
    p.add_argument("--use_yfinance", action="store_true")

    # costs (should match optimization)
    p.add_argument("--stt_rate", type=float, default=0.0018)
    p.add_argument("--commission_rate", type=float, default=0.0)
    p.add_argument("--short_borrow_annual_rate", type=float, default=0.04)
    p.add_argument("--short_borrow_day_count", type=int, default=365)

    args = p.parse_args()

    if not args.use_yfinance and not args.panel_csv:
        raise SystemExit("Provide --panel_csv (recommended) or use --use_yfinance.")

    valid_start = _parse_date(args.valid_start)
    valid_end = _parse_date(args.valid_end)
    fetch_start = _warmup_start(valid_start, args.warmup_days).strftime("%Y-%m-%d")

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    strat_cfg = _load_params(args.params)

    cost_cfg = CostConfig(
        stt_rate=float(args.stt_rate),
        commission_rate=float(args.commission_rate),
        short_borrow_annual_rate=float(args.short_borrow_annual_rate),
        short_borrow_day_count=int(args.short_borrow_day_count),
    )
    ind_cfg = IndicatorConfig()

    frame = _load_frame(args, fetch_start=fetch_start, end=args.valid_end)

    paths = _run_core(
        frame=frame,
        output_dir=out_dir,
        ind_cfg=ind_cfg,
        strat_cfg=strat_cfg,
        cost_cfg=cost_cfg,
        start_dt=valid_start,
        end_dt=valid_end,
    )

    eq = pd.read_csv(paths["equity"], parse_dates=["Date"]).set_index("Date")["Equity"]
    print("VALID final equity:", float(eq.iloc[-1]) if len(eq) else float("nan"))
    print("VALID CAGR:", cagr(eq))
    print("VALID MaxDD:", max_drawdown(eq))

    (out_dir / "used_params.json").write_text(json.dumps(strat_cfg.__dict__, indent=2), encoding="utf-8")
    print("Saved outputs to:", out_dir)


if __name__ == "__main__":
    main()
