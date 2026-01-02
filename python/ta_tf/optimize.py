"""Very small random-search optimizer for Step-1.

This exists only to replicate the MATLAB 'optimize_random' concept for Step-1.
For later phases, it is recommended to replace this with a mature library.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

import pandas as pd

from .backtest import _run_core
from .config import CostConfig, IndicatorConfig, StrategyConfig
from .data_manager import OhlcvDataManager
from .data_provider import OhlcvFrame
from .metrics import cagr, max_drawdown


@dataclass(frozen=True)
class OptResult:
    score: float
    cagr: float
    max_dd: float
    params: StrategyConfig


def _score_equity(eq: pd.Series, dd_penalty: float) -> tuple[float, float, float]:
    mdd = max_drawdown(eq)
    g = cagr(eq)
    if not (pd.notna(g) and pd.notna(mdd)):
        return float("-inf"), float("nan"), float("nan")
    score = float(g - dd_penalty * mdd)
    return score, float(g), float(mdd)


def random_search_step1(
    frame: OhlcvFrame,
    train_start: str,
    train_end: str,
    n_evals: int = 200,
    seed: int = 7,
    dd_penalty: float = 0.5,
    output_dir: str | Path = "outputs_opt",
    ind_cfg: IndicatorConfig = IndicatorConfig(),
    cost_cfg: CostConfig = CostConfig(),
) -> list[OptResult]:
    """Random search over a small hand-picked grid."""
    random.seed(seed)
    out_dir = Path(output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # candidate grids (keep it small in Step-1)
    spread_enter = [0.0015, 0.0020, 0.0030, 0.0040, 0.0050]
    spread_exit = [0.0003, 0.0007, 0.0010, 0.0015]
    atr_enter_k = [0.15, 0.25, 0.35, 0.50, 0.70]
    atr_exit_k = [0.05, 0.10, 0.20]
    confirm_days = [1, 2, 3]
    min_hold = [1, 3, 5]
    cooldown = [0, 2, 5]

    results: list[OptResult] = []

    # Slice frame to training window (by index)
    df = frame.df
    df_train = df.loc[train_start:train_end].copy()
    frame_train = OhlcvFrame(df=df_train, symbol=frame.symbol)

    for k in range(int(n_evals)):
        cfg = StrategyConfig(
            spread_enter_pct=random.choice(spread_enter),
            spread_exit_pct=random.choice(spread_exit),
            use_atr_filter=True,
            atr_enter_k=random.choice(atr_enter_k),
            atr_exit_k=random.choice(atr_exit_k),
            confirm_days=random.choice(confirm_days),
            min_hold_bars=random.choice(min_hold),
            cooldown_bars=random.choice(cooldown),
        )

        paths = _run_core(frame_train, out_dir, ind_cfg, cfg, cost_cfg)
        eq = pd.read_csv(paths["equity"], parse_dates=["Date"]).set_index("Date")["Equity"]
        score, g, mdd = _score_equity(eq, dd_penalty=dd_penalty)
        results.append(OptResult(score=score, cagr=g, max_dd=mdd, params=cfg))

    # sort best-first
    results.sort(key=lambda r: r.score, reverse=True)

    # write summary
    rows = []
    for r in results:
        d = r.params.__dict__.copy()
        d.update({"score": r.score, "cagr": r.cagr, "max_dd": r.max_dd})
        rows.append(d)
    pd.DataFrame(rows).to_csv(out_dir / "opt_results.csv", index=False, encoding="utf-8")

    return results
