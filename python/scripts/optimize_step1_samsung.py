"""Example: optimize Step-1 on 2024 and validate on 2025."""

from __future__ import annotations

import argparse
from pathlib import Path

import pandas as pd

from ta_tf.config import CostConfig, IndicatorConfig, StrategyConfig
from ta_tf.data_provider import YfinanceProvider
from ta_tf.backtest import run_step1_from_yfinance
from ta_tf.metrics import cagr, max_drawdown
from ta_tf.optimize import random_search_step1


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--symbol", type=str, default="005930.KS")
    p.add_argument("--train_start", type=str, default="2024-01-01")
    p.add_argument("--train_end", type=str, default="2024-12-31")
    p.add_argument("--valid_start", type=str, default="2025-01-01")
    p.add_argument("--valid_end", type=str, default="2025-12-31")
    p.add_argument("--n", type=int, default=200)
    p.add_argument("--out", type=str, default="outputs_opt")
    args = p.parse_args()

    provider = YfinanceProvider()
    frame = provider.fetch(symbol=args.symbol, start=args.train_start, end=args.valid_end, interval="1d", auto_adjust=False)

    results = random_search_step1(
        frame=frame,
        train_start=args.train_start,
        train_end=args.train_end,
        n_evals=args.n,
        output_dir=args.out,
        ind_cfg=IndicatorConfig(),
        cost_cfg=CostConfig(),
    )

    best = results[0].params
    print("Best params (train):", best)

    # validate with best params
    out = run_step1_from_yfinance(
        symbol=args.symbol,
        start=args.valid_start,
        end=args.valid_end,
        interval="1d",
        output_dir=Path(args.out) / "valid",
        ind_cfg=IndicatorConfig(),
        strat_cfg=best,
        cost_cfg=CostConfig(),
    )
    eq = pd.read_csv(out["equity"], parse_dates=["Date"]).set_index("Date")["Equity"]
    print("VALID CAGR:", cagr(eq))
    print("VALID MaxDD:", max_drawdown(eq))


if __name__ == "__main__":
    main()
