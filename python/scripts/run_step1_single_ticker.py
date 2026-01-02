from __future__ import annotations

import argparse
import json
from pathlib import Path

import pandas as pd

from ta_tf.backtest import run_from_csv, run_yfinance
from ta_tf.config import CostConfig, StrategyConfig, BacktestConfig, IndicatorConfig
from ta_tf.data_provider import PanelCsvProvider
from ta_tf.data_manager import OhlcvDataManager
from ta_tf.trader import TickerTraderStep1


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
    p.add_argument("--output_dir", type=str, default="outputs")
    p.add_argument("--csv", type=str, default=None, help="Simple OHLCV CSV path (Date,Open,High,Low,Close,Volume).")
    p.add_argument("--panel_csv", type=str, default=None, help="Panel OHLC CSV (Date,Ticker,Open,High,Low,Close,...).")
    p.add_argument("--opt_xlsx", type=str, default=None, help="Optimizer results XLSX with ParamsJson column.")
    p.add_argument("--rank", type=int, default=1, help="Row rank (1-based) in the optimizer XLSX.")
    p.add_argument("--stt_rate", type=float, default=0.0018, help="Sell tax (STT) rate. Default 0.0018.")
    p.add_argument("--valuation_mode", type=str, default="CLOSE", help='Equity valuation mode: "CLOSE" or "NEXT_OPEN"')
    p.add_argument("--auto_adjust", action="store_true", help="Use yfinance auto_adjust (if using yfinance).")
    args = p.parse_args()

    strat_cfg = StrategyConfig()
    if args.opt_xlsx:
        params = load_paramsjson_from_xlsx(args.opt_xlsx, args.rank)
        strat_cfg = StrategyConfig.from_params_dict(params)

    cost_cfg = CostConfig(stt_rate=float(args.stt_rate))

    if args.panel_csv:
        frame = PanelCsvProvider().fetch(args.panel_csv, args.symbol, start=args.start, end=args.end)
        dm = OhlcvDataManager(frame, IndicatorConfig())
        bt_cfg = BacktestConfig(
            symbol=frame.symbol,
            initial_capital=1_000_000_000.0,
            valuation_mode=str(args.valuation_mode).upper(),
            initial_equity=1.0,
        )
        trader = TickerTraderStep1(dm=dm, strat_cfg=strat_cfg, cost_cfg=cost_cfg, bt_cfg=bt_cfg)
        trader.run_full_backtest()

        out_dir = Path(args.output_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        eq = pd.DataFrame(trader.equity_curve, columns=["Date", "Equity"]).set_index("Date")
        tr = pd.DataFrame([x.__dict__ for x in trader.trade_log])
        eq_path = out_dir / f"equity_{args.symbol.replace('.','_')}.csv"
        tr_path = out_dir / f"trades_{args.symbol.replace('.','_')}.csv"
        eq.to_csv(eq_path, encoding="utf-8")
        tr.to_csv(tr_path, index=False, encoding="utf-8")
        print(eq_path)
        print(tr_path)
        return

    if args.csv:
        paths = run_from_csv(
            csv_path=args.csv,
            symbol=args.symbol,
            output_dir=args.output_dir,
            strat_cfg=strat_cfg,
            cost_cfg=cost_cfg,
        )
    else:
        paths = run_yfinance(
            symbol=args.symbol,
            start=args.start,
            end=args.end,
            output_dir=args.output_dir,
            strat_cfg=strat_cfg,
            cost_cfg=cost_cfg,
            auto_adjust=args.auto_adjust,
            include_warmup=True,
        )
    print(paths["equity"])
    print(paths["trades"])


if __name__ == "__main__":
    main()
