"""Optimize Step-1 single-trader strategy on 2020-2024 (Samsung by default).

This script is intentionally simple and self-contained:
- loads OHLC data (panel CSV recommended; yfinance optional)
- runs a small random-search over a hand-picked parameter grid
- scores each run on the TRAIN window only (warmup data is used for indicators)
- writes results to CSV and the best params to JSON

Example (panel CSV):
    python -m scripts.optimize_2020_2024_single \
      --panel_csv kospi_top100_ohlc_30y.csv --symbol 005930.KS \
      --train_start 2020-01-01 --train_end 2024-12-31 \
      --n_evals 800 --seed 7 --out outputs_opt_2020_2024

Example (yfinance daily):
    python -m scripts.optimize_2020_2024_single \
      --symbol 005930.KS --train_start 2020-01-01 --train_end 2024-12-31 \
      --n_evals 400 --out outputs_opt_2020_2024 --use_yfinance
"""

from __future__ import annotations

import argparse
import json
import random
from dataclasses import asdict, replace
from pathlib import Path

import pandas as pd

from ta_tf.config import CostConfig, IndicatorConfig, StrategyConfig
from ta_tf.data_provider import PanelCsvProvider, YfinanceProvider, OhlcvFrame
from ta_tf.backtest import _run_core
from ta_tf.metrics import cagr, max_drawdown


def _parse_date(s: str) -> pd.Timestamp:
    return pd.to_datetime(s).tz_localize(None)


def _warmup_start(train_start: pd.Timestamp, warmup_days: int) -> pd.Timestamp:
    return (train_start - pd.Timedelta(days=int(warmup_days))).tz_localize(None)


def _score(eq: pd.Series, dd_penalty: float) -> tuple[float, float, float]:
    g = cagr(eq)
    mdd = max_drawdown(eq)
    score = float(g) - float(dd_penalty) * float(mdd)
    return score, float(g), float(mdd)


def _sample_params(rng: random.Random) -> StrategyConfig:
    """Sample one StrategyConfig from a small grid.

    Keep this grid compact and interpretable; expand later as needed.
    """
    # grids (tuned to resemble MATLAB Step-1 knobs)
    spread_enter = [0.0015, 0.0020, 0.0030, 0.0040, 0.0050]
    spread_exit = [0.0003, 0.0007, 0.0010, 0.0015]

    use_atr = [True, True, True, False]  # bias to True
    atr_enter_k = [0.10, 0.15, 0.25, 0.35, 0.50, 0.70]
    atr_exit_k = [0.05, 0.10, 0.20]

    confirm_days = [1, 2, 3, 4]
    min_hold = [1, 3, 5, 7]
    cooldown = [0, 2, 5, 10]

    use_long_trend = [True, True, False]  # bias to True
    use_short_trend = [False, False, True]  # bias to False
    enable_short = [True, True, True, False]  # bias to True

    # Stops: keep within sensible bounds for daily bars
    long_daily_stop = [0.02, 0.03, 0.05, 0.08]
    long_trail_stop = [0.06, 0.10, 0.15]
    short_daily_stop = [0.02, 0.03, 0.05, 0.08]
    short_trail_stop = [0.06, 0.10, 0.15]

    use_prev_close_filter = [False, False, True]

    # MACD knobs (optional; keep off-biased)
    use_macd_regime_filter = [False, False, True]
    use_macd_exit = [False, False, True]
    macd_signal_mode = ["cross", "hist"]
    use_macd_size_scaling = [False, False, True]
    macd_size_min = [0.5, 0.6, 0.7]
    macd_size_max = [0.9, 1.0]
    macd_size_atr_k = [0.8, 1.0, 1.2]

    cfg = StrategyConfig(
        spread_enter_pct=rng.choice(spread_enter),
        spread_exit_pct=rng.choice(spread_exit),
        use_atr_filter=rng.choice(use_atr),
        atr_enter_k=rng.choice(atr_enter_k),
        atr_exit_k=rng.choice(atr_exit_k),
        confirm_days=int(rng.choice(confirm_days)),
        min_hold_bars=int(rng.choice(min_hold)),
        cooldown_bars=int(rng.choice(cooldown)),
        use_long_trend_filter=bool(rng.choice(use_long_trend)),
        use_short_trend_filter=bool(rng.choice(use_short_trend)),
        enable_short=bool(rng.choice(enable_short)),
        long_daily_stop=float(rng.choice(long_daily_stop)),
        long_trail_stop=float(rng.choice(long_trail_stop)),
        short_daily_stop=float(rng.choice(short_daily_stop)),
        short_trail_stop=float(rng.choice(short_trail_stop)),
        use_prev_close_filter=bool(rng.choice(use_prev_close_filter)),
        # Keep single-trader mode fixed
        max_units=1,
        pyramid_step_return=1e9,
        give_up_max_bars=0,
        give_up_drawdown_pct=0.0,
        # MACD
        use_macd_regime_filter=bool(rng.choice(use_macd_regime_filter)),
        use_macd_exit=bool(rng.choice(use_macd_exit)),
        macd_signal_mode=str(rng.choice(macd_signal_mode)),
        use_macd_size_scaling=bool(rng.choice(use_macd_size_scaling)),
        macd_size_min=float(rng.choice(macd_size_min)),
        macd_size_max=float(rng.choice(macd_size_max)),
        macd_size_atr_k=float(rng.choice(macd_size_atr_k)),
    )
    # Sanity: min <= max for MACD scaling
    if cfg.macd_size_min > cfg.macd_size_max:
        cfg = replace(cfg, macd_size_min=cfg.macd_size_max, macd_size_max=cfg.macd_size_min)
    return cfg


def _load_frame(args) -> OhlcvFrame:
    if args.use_yfinance:
        prov = YfinanceProvider()
        # fetch a bit extra for warmup
        return prov.fetch(args.symbol, start=args.fetch_start, end=args.train_end, interval="1d")
    if not args.panel_csv:
        raise ValueError("Either --panel_csv must be provided, or set --use_yfinance.")
    prov = PanelCsvProvider()
    return prov.fetch(args.panel_csv, args.symbol, start=args.fetch_start, end=args.train_end)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--symbol", type=str, default="005930.KS")
    p.add_argument("--train_start", type=str, default="2020-01-01")
    p.add_argument("--train_end", type=str, default="2024-12-31")
    p.add_argument("--warmup_days", type=int, default=900, help="Days of warmup history before train_start.")
    p.add_argument("--n_evals", type=int, default=800)
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--dd_penalty", type=float, default=0.50)
    p.add_argument("--out", type=str, default="outputs_opt_2020_2024")

    # data source
    p.add_argument("--panel_csv", type=str, default=None, help="Panel OHLC CSV (Date,Ticker,Open,High,Low,Close,...)")
    p.add_argument("--use_yfinance", action="store_true", help="Use yfinance daily instead of panel CSV.")

    # costs
    p.add_argument("--stt_rate", type=float, default=0.0018)
    p.add_argument("--commission_rate", type=float, default=0.0)
    p.add_argument("--short_borrow_annual_rate", type=float, default=0.04)
    p.add_argument("--short_borrow_day_count", type=int, default=365)

    args = p.parse_args()

    train_start = _parse_date(args.train_start)
    train_end = _parse_date(args.train_end)
    fetch_start = _warmup_start(train_start, args.warmup_days)
    args.fetch_start = fetch_start.strftime("%Y-%m-%d")

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    # Configs
    ind_cfg = IndicatorConfig()
    cost_cfg = CostConfig(
        stt_rate=float(args.stt_rate),
        commission_rate=float(args.commission_rate),
        short_borrow_annual_rate=float(args.short_borrow_annual_rate),
        short_borrow_day_count=int(args.short_borrow_day_count),
    )

    frame = _load_frame(args)

    rng = random.Random(int(args.seed))

    results = []
    best = None
    best_score = -1e99

    # metadata
    meta = {
        "symbol": args.symbol,
        "train_start": args.train_start,
        "train_end": args.train_end,
        "fetch_start": args.fetch_start,
        "n_evals": int(args.n_evals),
        "seed": int(args.seed),
        "dd_penalty": float(args.dd_penalty),
        "data_source": "yfinance" if args.use_yfinance else "panel_csv",
        "panel_csv": args.panel_csv,
        "cost_cfg": asdict(cost_cfg),
    }
    (out_dir / "meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")

    # run
    for k in range(int(args.n_evals)):
        strat_cfg = _sample_params(rng)
        eval_dir = out_dir / f"eval_{k:05d}"
        paths = _run_core(
            frame=frame,
            output_dir=eval_dir,
            ind_cfg=ind_cfg,
            strat_cfg=strat_cfg,
            cost_cfg=cost_cfg,
            start_dt=train_start,
            end_dt=train_end,
        )
        eq = pd.read_csv(paths["equity"], parse_dates=["Date"]).set_index("Date")["Equity"]
        sc, g, mdd = _score(eq, dd_penalty=float(args.dd_penalty))

        row = strat_cfg.__dict__.copy()
        row.update({"score": sc, "cagr": g, "max_dd": mdd, "final_equity": float(eq.iloc[-1]) if len(eq) else float("nan")})
        results.append(row)

        if sc > best_score:
            best_score = sc
            best = strat_cfg
            # write best-so-far
            (out_dir / "best_params.json").write_text(json.dumps(best.__dict__, indent=2), encoding="utf-8")
            (out_dir / "best_score.txt").write_text(f"{best_score}\n", encoding="utf-8")

        if (k + 1) % max(1, int(args.n_evals) // 20) == 0:
            print(f"[{k+1}/{args.n_evals}] best_score={best_score:.6f}")

    df = pd.DataFrame(results).sort_values("score", ascending=False)
    df.to_csv(out_dir / "opt_results.csv", index=False, encoding="utf-8")
    print(f"Saved: {out_dir / 'opt_results.csv'}")
    if best is not None:
        print("Best params saved to:", out_dir / "best_params.json")
        print("Best final equity (train):", df.iloc[0]["final_equity"])
        print("Best CAGR (train):", df.iloc[0]["cagr"])
        print("Best MaxDD (train):", df.iloc[0]["max_dd"])


if __name__ == "__main__":
    main()
