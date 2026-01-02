"""Compare Step-1 python equity curve to a reference equity curve CSV.

Reference formats supported:
- MATLAB export: columns [Time, Data]
- Python export: columns [Date, Equity]

This script also supports loading MATLAB optimizer ParamsJson from an XLSX
(opt_results_*.xlsx) and applying it to the Step-1 StrategyConfig.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd


def load_reference(path: str) -> pd.DataFrame:
    p = Path(path)
    df = pd.read_csv(p)
    cols = [c.strip().lower() for c in df.columns]
    if "time" in cols and "data" in cols:
        tcol = df.columns[cols.index("time")]
        dcol = df.columns[cols.index("data")]
        out = df[[tcol, dcol]].copy()
        out.columns = ["Date", "Equity"]
    elif "date" in cols and "equity" in cols:
        dcol = df.columns[cols.index("date")]
        ecol = df.columns[cols.index("equity")]
        out = df[[dcol, ecol]].copy()
        out.columns = ["Date", "Equity"]
    else:
        raise ValueError("Unsupported reference format. Expected [Time,Data] or [Date,Equity].")

    out["Date"] = pd.to_datetime(out["Date"])
    out = out.set_index("Date").sort_index()
    out["Equity"] = out["Equity"].astype(float)
    return out


def load_paramsjson_from_xlsx(xlsx_path: str, rank: int) -> dict:
    df = pd.read_excel(xlsx_path)
    if "ParamsJson" not in df.columns:
        raise ValueError("XLSX must contain a ParamsJson column.")
    idx = max(0, int(rank) - 1)
    idx = min(idx, len(df) - 1)
    return json.loads(df.loc[idx, "ParamsJson"])


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--symbol", type=str, default="005930.KS")
    p.add_argument("--start", type=str, default="2016-12-31")
    p.add_argument("--end", type=str, default="2020-12-31")
    p.add_argument("--ref", type=str, required=True, help="Reference curve CSV (MATLAB: Time,Data).")
    p.add_argument("--output_dir", type=str, default="outputs_cmp")
    p.add_argument("--plot", action="store_true", help="Save a PNG plot next to outputs.")
    p.add_argument("--opt_xlsx", type=str, default=None, help="Optimizer results XLSX with ParamsJson column.")
    p.add_argument("--rank", type=int, default=1, help="Row rank (1-based) in the optimizer XLSX.")
    p.add_argument("--panel_csv", type=str, default=None, help="Panel OHLC CSV (Date,Ticker,Open,High,Low,Close,...)")
    p.add_argument("--stt_rate", type=float, default=0.0018, help="Sell tax (STT) rate. Default 0.0018.")
    p.add_argument("--valuation_mode", type=str, default="CLOSE", help='Equity valuation mode: "CLOSE" or "NEXT_OPEN"')
    args = p.parse_args()

    from ta_tf.config import CostConfig, StrategyConfig, BacktestConfig, IndicatorConfig
    from ta_tf.data_provider import PanelCsvProvider
    from ta_tf.data_manager import OhlcvDataManager
    from ta_tf.trader import TickerTraderStep1
    from ta_tf.backtest import run_yfinance

    strat_cfg = StrategyConfig()
    if args.opt_xlsx:
        params = load_paramsjson_from_xlsx(args.opt_xlsx, args.rank)
        strat_cfg = StrategyConfig.from_params_dict(params)

    cost_cfg = CostConfig(stt_rate=float(args.stt_rate))
    ind_cfg = IndicatorConfig()

    if args.panel_csv:
        frame = PanelCsvProvider().fetch(args.panel_csv, args.symbol, start=args.start, end=args.end)
        dm = OhlcvDataManager(frame, ind_cfg)
        bt_cfg = BacktestConfig(
            symbol=frame.symbol,
            initial_capital=1_000_000_000.0,
            valuation_mode=str(args.valuation_mode).upper(),
            initial_equity=1.0,
        )
        trader = TickerTraderStep1(dm=dm, strat_cfg=strat_cfg, cost_cfg=cost_cfg, bt_cfg=bt_cfg)
        trader.run_full_backtest()
        sim = pd.DataFrame(trader.equity_curve, columns=["Date", "Equity"]).set_index("Date")
        out_dir = Path(args.output_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        sim_path = out_dir / f"equity_{args.symbol.replace('.','_')}_python.csv"
        sim.to_csv(sim_path, encoding="utf-8")
    else:
        paths = run_yfinance(
            symbol=args.symbol,
            start=args.start,
            end=args.end,
            output_dir=args.output_dir,
            strat_cfg=strat_cfg,
            cost_cfg=cost_cfg,
            auto_adjust=False,
            include_warmup=True,
        )
        sim = pd.read_csv(paths["equity"], index_col=0, parse_dates=True)

    ref = load_reference(args.ref)

    idx = ref.index.intersection(sim.index)
    refa = ref.loc[idx, "Equity"].astype(float)
    sima = sim.loc[idx, "Equity"].astype(float)

    refn = refa / refa.iloc[0]
    simn = sima / sima.iloc[0]

    diff = simn - refn
    rmse = float(np.sqrt(np.mean(diff**2)))
    mae = float(np.mean(np.abs(diff)))
    max_abs = float(np.max(np.abs(diff)))

    corr = float("nan")
    if len(idx) > 2:
        corr = float(np.corrcoef(refn.values, simn.values)[0, 1])

    print(f"Aligned points: {len(idx)}")
    print(f"RMSE: {rmse:.6f}")
    print(f"MAE: {mae:.6f}")
    print(f"MaxAbs: {max_abs:.6f}")
    print(f"Corr: {corr:.6f}")

    if args.plot:
        import matplotlib.pyplot as plt

        plt.figure()
        plt.plot(refn.index, refn.values, label="reference")
        plt.plot(simn.index, simn.values, label="python")
        plt.legend()
        plt.title(f"{args.symbol} normalized equity")
        plt.tight_layout()
        out_png = Path(args.output_dir) / "equity_compare.png"
        plt.savefig(out_png, dpi=150)
        print(f"Saved plot: {out_png}")


if __name__ == "__main__":
    main()
