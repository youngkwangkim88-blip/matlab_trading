"""Configuration objects.

Style rules:
- keep signatures stable (no alias chaos)
- prefer explicit field names
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class IndicatorConfig:
    """Indicator window configuration."""

    sma_week: int = 5
    sma_fast: int = 20
    # MATLAB prototype uses 40 for "slow" (SMA40).
    sma_slow: int = 40
    sma_long_term: int = 180
    long_trend_lookback: int = 20
    atr_window: int = 14

    macd_fast: int = 12
    macd_slow: int = 26
    macd_signal: int = 9


@dataclass(frozen=True)
class StrategyConfig:
    """Step-1 strategy parameters (subset of the MATLAB knobs)."""

    # separation gate between sma_week and sma_fast
    # MATLAB defaults
    spread_enter_pct: float = 0.0030
    spread_exit_pct: float = 0.0010

    # ATR-normalized separation (if enabled)
    use_atr_filter: bool = True
    atr_enter_k: float = 0.35
    atr_exit_k: float = 0.10

    # confirmation / anti-whipsaw
    confirm_days: int = 2
    min_hold_bars: int = 3
    cooldown_bars: int = 0

    # trend filters
    use_long_trend_filter: bool = True
    use_short_trend_filter: bool = False

    # allow shorts at all
    enable_short: bool = True

    # stops (intrabar: use H/L of current bar)
    long_daily_stop: float = 0.05
    long_trail_stop: float = 0.10
    short_daily_stop: float = 0.03
    short_trail_stop: float = 0.10

    # prev-close filter (MATLAB default off)
    use_prev_close_filter: bool = False
    prev_close_filter_ref: str = "fast"  # 'week' or 'fast'

    # MACD features (optional)
    use_macd_regime_filter: bool = False
    use_macd_exit: bool = False
    # MACD options (used by optimizer; default OFF)
    macd_signal_mode: str = "cross"  # 'cross' or 'hist'
    use_macd_size_scaling: bool = False
    macd_size_min: float = 0.6
    macd_size_max: float = 1.0
    macd_size_atr_k: float = 1.0


    # NOTE: MATLAB prototype's baseline trader has **no** pyramiding and no give-up rule.
    # We keep fields for future extension, but defaults keep behavior off.
    max_units: int = 1
    pyramid_step_return: float = 1e9  # effectively disabled
    give_up_max_bars: int = 0
    give_up_drawdown_pct: float = 0.0

    @classmethod
    def from_params_dict(cls, d: dict) -> "StrategyConfig":
        """Create StrategyConfig from MATLAB optimizer ParamsJson dict.

        Keys are typically PascalCase (e.g., SpreadEnterPct). Unknown keys are ignored.
        """
        mapping = {
            "SpreadEnterPct": "spread_enter_pct",
            "SpreadExitPct": "spread_exit_pct",
            "UseATRFilter": "use_atr_filter",
            "AtrEnterK": "atr_enter_k",
            "AtrExitK": "atr_exit_k",
            "ConfirmDays": "confirm_days",
            "MinHoldDays": "min_hold_bars",
            "CooldownDays": "cooldown_bars",
            "UseLongTrendFilter": "use_long_trend_filter",
            "UseShortTrendFilter": "use_short_trend_filter",
            "EnableShort": "enable_short",
            "LongDailyStop": "long_daily_stop",
            "LongTrailStop": "long_trail_stop",
            "ShortDailyStop": "short_daily_stop",
            "ShortTrailStop": "short_trail_stop",
            "UsePrevCloseFilter": "use_prev_close_filter",
            "PrevCloseFilterRef": "prev_close_filter_ref",
            "UseMACDRegimeFilter": "use_macd_regime_filter",
            "UseMACDExit": "use_macd_exit",
            "MACDSignalMode": "macd_signal_mode",
            "UseMACDSizeScaling": "use_macd_size_scaling",
            "MACDSizeMin": "macd_size_min",
            "MACDSizeMax": "macd_size_max",
            "MACDSizeAtrK": "macd_size_atr_k",
        }
        kwargs = {}
        for k, v in (d or {}).items():
            if k in mapping:
                kwargs[mapping[k]] = v

        if isinstance(kwargs.get("macd_signal_mode"), str):
            kwargs["macd_signal_mode"] = kwargs["macd_signal_mode"].lower()
        if isinstance(kwargs.get("prev_close_filter_ref"), str):
            kwargs["prev_close_filter_ref"] = kwargs["prev_close_filter_ref"].lower()

        return cls(**kwargs)



@dataclass(frozen=True)
class CostConfig:
    """KRX-like costs and constraints."""

    # Sell tax (STT): applies to SELL trades only.
    # Many MATLAB runs use external accounting; defaults keep costs modest.
    stt_rate: float = 0.0018

    # Commission (optional)
    commission_rate: float = 0.0000

    # Short borrow cost (annual) -> daily applied while short
    short_borrow_annual_rate: float = 0.04

    # Day-count convention for converting annual borrow rate to daily.
    # For stock-borrow interest, calendar-day /365 is often a reasonable default.
    short_borrow_day_count: int = 365

    # Short must be covered within 90 calendar days (MATLAB default OFF)
    enforce_short_max_hold: bool = False
    short_max_hold_days: int = 90


@dataclass(frozen=True)
class BacktestConfig:
    """Backtest run configuration.

    Notes:
    - MATLAB reference uses eng.ValuationMode = "CLOSE" for the equity curve.
    - We keep `initial_equity` for legacy normalized runs, but Step-1 v3 uses
      `initial_capital` + cash/qty accounting and then normalizes by initial_capital.
    """

    symbol: str = "005930.KS"

    # Portfolio-style accounting base (KRW notional)
    initial_capital: float = 1_000_000_000.0  # 10억 default

    # Equity curve valuation: "CLOSE" (default) or "NEXT_OPEN" (legacy)
    valuation_mode: str = "CLOSE"

    # Legacy normalized mode (kept for compatibility)
    initial_equity: float = 1.0
