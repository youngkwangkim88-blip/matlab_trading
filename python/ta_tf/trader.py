"""MATLAB-compatible single-symbol trader (Step-1).

This is a direct conceptual port of the MATLAB `ticker_trader.step()` loop:
- uses previous-bar indicators (`PrevContext`)
- executes position changes at Open(t)
- marks-to-market Open(t) -> Open(t+1)
- supports intrabar stop checks using (O,H,L,C) at bar t
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import List, Optional, Tuple

import numpy as np

from .config import BacktestConfig, CostConfig, StrategyConfig
from .cost_model import KRXCostModel
from .data_manager import OhlcvDataManager
from .types import PrevContext, TradeEvent


def _is_finite(x: float) -> bool:
    return bool(np.isfinite(x))


@dataclass
class _PositionState:
    pos: int = 0  # -1/0/+1
    units: int = 0  # 0..max_units
    entry_price: float = float("nan")
    entry_time: Optional[datetime] = None
    entry_index: Optional[int] = None

    position_frac: float = 1.0  # units/max_units

    hist_max: float = float("-inf")
    hist_min: float = float("inf")

    cooldown_until_index: int = -1

    # for give-up rule
    best_since_entry: float = float("nan")
    worst_since_entry: float = float("nan")


class TickerTraderStep1:
    """A MATLAB-compatible single-symbol trader (Step-1 baseline).

    This aims to match the behavior of the MATLAB `ticker_trader.step()` loop:
    - prev-bar context
    - execute at Open(t)
    - mark-to-market Open(t)->Open(t+1)
    - intrabar stops using H/L
    """

    def __init__(
        self,
        dm: OhlcvDataManager,
        strat_cfg: StrategyConfig,
        cost_cfg: CostConfig,
        bt_cfg: BacktestConfig,
    ):
        self.dm = dm
        self.symbol = bt_cfg.symbol
        self.bt_cfg = bt_cfg
        self.strat_cfg = strat_cfg
        self.cost_model = KRXCostModel(cost_cfg)

        # Portfolio-style accounting base (KRW notional) and normalized equity
        self.initial_capital = float(bt_cfg.initial_capital)
        self.initial_equity = float(bt_cfg.initial_equity)

        # Cash + shares accounting (shares signed: +long, -short)
        self.cash = float(self.initial_capital)
        self.shares = int(0)

        self.equity = float(self.initial_equity)  # normalized by initial_capital

        self.state = _PositionState()
        self.trade_log: List[TradeEvent] = []
        self.equity_curve: List[Tuple[datetime, float]] = []

        self._short_borrow_daily = self.cost_model.short_borrow_daily_rate()
        self._max_units = max(1, int(strat_cfg.max_units))

    def _equity_value(self, price: float) -> float:
        """Current equity in KRW given a valuation price."""
        return float(self.cash + float(self.shares) * float(price))

    def _equity_norm(self, price: float) -> float:
        """Normalized equity (starts at initial_equity)."""
        base = self.initial_capital if self.initial_capital > 0 else 1.0
        return float(self.initial_equity * (self._equity_value(price) / base))

    # ---------- public API ----------

    def run_full_backtest(self) -> None:
        """Run full history in the data manager."""
        n = len(self.dm)
        # we need t and t+1 opens, so stop at n-2
        for t in range(0, max(0, n - 1)):
            self.step(t)

    def step(self, t: int) -> None:
        """Process bar index t, consistent with MATLAB signature: step(tIdx)."""
        n = len(self.dm)
        if t < 2 or t > n - 2:
            return

        ts = self.dm.get_bar_timestamp(t)
        O, H, L, C = self.dm.get_ohlc(t)

        # 2) Update extrema and give-up trackers
        if self.state.pos != 0:
            self._update_history_extrema(O, C)

        # 2.5) Regulatory forced cover for short max holding period
        if self._should_force_cover_short(ts):
            self._exit_all(t, ts, O, reason="FORCED_COVER_MAXHOLD", is_stop=False)
            # End-of-day valuation (no position after forced cover)
            self._append_equity(ts, valuation_price=C)
            return

        # 3) Intrabar stop check
        stop_hit, stop_type, stop_px, hist_ref = self._check_stop_intrabar(O, H, L, C)
        if stop_hit:
            self._exit_all(t, ts, stop_px, reason=f"STOP:{stop_type}", is_stop=True)
            # Intrabar exit: no borrow cost for the rest of the day.
            self._append_equity(ts, valuation_price=C)
            return

        # 4) Prev-bar context
        ctx = self.dm.get_prev_context(t)
        if not ctx.valid:
            self._append_equity(ts, valuation_price=C)
            return

        # 5) Signal decision
        target = self._decide_target(t, ctx)

        # 6) Apply target at Open(t)
        if target != self.state.pos:
            if self.state.pos != 0:
                self._exit_all(t, ts, O, reason="SignalExit", is_stop=False)
            if target != 0:
                self._enter_new(t, ts, O, target, reason="SignalEntry", ctx=ctx)

        # (No pyramiding in the MATLAB baseline; keep disabled by default.)
        self._maybe_add_unit(t, ts, O)

        # 7) Daily short borrow interest (cash deduction) at end of bar.
        # Use current borrowed balance (abs(shares) * close) * rate/day_count.
        if self.shares < 0 and _is_finite(C):
            borrow_cost = float(abs(self.shares)) * float(C) * float(self._short_borrow_daily)
            self.cash -= borrow_cost

        # 8) Record equity according to valuation mode.
        if str(self.bt_cfg.valuation_mode).upper() == "CLOSE":
            P = C
        else:
            P = self.dm.get_open(t + 1)
        self._append_equity(ts, valuation_price=P)

    # ---------- internal helpers ----------

    def _append_equity(self, ts: datetime, valuation_price: float) -> None:
        # Update normalized equity field for compatibility
        self.equity = self._equity_norm(valuation_price)
        self.equity_curve.append((ts, float(self.equity)))

    def _update_history_extrema(self, O: float, C: float) -> None:
        oc_max = max(O, C)
        oc_min = min(O, C)

        if self.state.pos == 1:
            self.state.hist_max = max(self.state.hist_max, oc_max)
        elif self.state.pos == -1:
            self.state.hist_min = min(self.state.hist_min, oc_min)

        # give-up trackers
        if self.state.entry_price == self.state.entry_price:  # not NaN
            self.state.best_since_entry = (
                max(self.state.best_since_entry, oc_max)
                if _is_finite(self.state.best_since_entry)
                else oc_max
            )
            self.state.worst_since_entry = (
                min(self.state.worst_since_entry, oc_min)
                if _is_finite(self.state.worst_since_entry)
                else oc_min
            )

    def _should_force_cover_short(self, ts: datetime) -> bool:
        cfg = self.cost_model.cfg
        if not cfg.enforce_short_max_hold:
            return False
        if self.state.pos != -1 or self.state.entry_time is None:
            return False
        held_days = (ts.date() - self.state.entry_time.date()).days
        return held_days >= int(cfg.short_max_hold_days)

    def _check_stop_intrabar(self, O: float, H: float, L: float, C: float) -> Tuple[bool, str, float, float]:
        if self.state.pos == 0 or self.state.units == 0:
            return False, "", float("nan"), float("nan")

        if self.state.pos == 1:
            daily_px = O * (1.0 - self.strat_cfg.long_daily_stop)
            trail_px = self.state.hist_max * (1.0 - self.strat_cfg.long_trail_stop)
            px = max(daily_px, trail_px)
            if L <= px:
                hist_ref = float(self.state.hist_max)
                return True, "LONG", float(px), hist_ref
        else:
            daily_px = O * (1.0 + self.strat_cfg.short_daily_stop)
            trail_px = self.state.hist_min * (1.0 + self.strat_cfg.short_trail_stop)
            px = min(daily_px, trail_px)
            if H >= px:
                hist_ref = float(self.state.hist_min)
                return True, "SHORT", float(px), hist_ref

        return False, "", float("nan"), float("nan")

    def _should_give_up(self, t: int, O: float) -> bool:
        """Compatibility hook (disabled by default).

        MATLAB baseline trader does not include this rule. We keep it as an
        optional extension (give_up_max_bars>0).
        """
        cfg = self.strat_cfg
        if cfg.give_up_max_bars <= 0:
            return False
        st = self.state
        if st.pos == 0 or st.entry_index is None:
            return False
        bars_held = t - st.entry_index
        if bars_held < 0 or bars_held > cfg.give_up_max_bars:
            return False
        if st.pos == 1 and _is_finite(st.best_since_entry) and _is_finite(O):
            dd = (st.best_since_entry / O) - 1.0
            return dd >= cfg.give_up_drawdown_pct
        if st.pos == -1 and _is_finite(st.worst_since_entry) and _is_finite(O):
            dd = (O / st.worst_since_entry) - 1.0
            return dd >= cfg.give_up_drawdown_pct
        return False

    def _decide_target(self, t: int, ctx: PrevContext) -> int:
        # Port of MATLAB ticker_trader.decide_target()
        cfg = self.strat_cfg

        # Cooldown block on new entries
        if self.state.pos == 0 and t <= self.state.cooldown_until_index:
            return 0

        week = ctx.sma_week_prev
        fast = ctx.sma_fast_prev
        slow = ctx.sma_slow_prev
        trend = ctx.long_term_trend_prev
        atr = ctx.atr_prev
        close_prev = ctx.close_prev

        if not (_is_finite(week) and _is_finite(fast) and _is_finite(slow)):
            return 0

        long_stack = (week > fast) and (fast > slow)
        short_stack = (slow > fast) and (fast > week)

        sep_long = (week - fast)   # >0 helps long
        sep_short = (fast - week)  # >0 helps short
        den = max(abs(fast), np.finfo(float).tiny)

        if cfg.use_atr_filter and _is_finite(atr) and atr > 0:
            enter_long_ok = sep_long >= (cfg.atr_enter_k * atr)
            exit_long_ok = sep_long <= (cfg.atr_exit_k * atr)
            enter_short_ok = sep_short >= (cfg.atr_enter_k * atr)
            exit_short_ok = sep_short <= (cfg.atr_exit_k * atr)
        else:
            enter_long_ok = (sep_long / den) >= cfg.spread_enter_pct
            exit_long_ok = (sep_long / den) <= cfg.spread_exit_pct
            enter_short_ok = (sep_short / den) >= cfg.spread_enter_pct
            exit_short_ok = (sep_short / den) <= cfg.spread_exit_pct

        # trend filters
        trend_long_ok = (trend == 1) if cfg.use_long_trend_filter else True
        trend_short_ok = (trend == -1) if cfg.use_short_trend_filter else True

        macd_bull, macd_bear = self._macd_state(ctx)
        macd_long_ok = macd_bull if cfg.use_macd_regime_filter else True
        macd_short_ok = macd_bear if cfg.use_macd_regime_filter else True

        # confirmation: MATLAB calls check_confirm_*(t-1, confN)
        conf_n = max(1, int(cfg.confirm_days))
        long_conf = self._check_confirm_long(t - 1, conf_n)
        short_conf = self._check_confirm_short(t - 1, conf_n)

        # prev-close gating (optional)
        prev_close_long_ok = True
        prev_close_short_ok = True
        if cfg.use_prev_close_filter and _is_finite(close_prev):
            ref_ma = week if cfg.prev_close_filter_ref == "week" else fast
            if _is_finite(ref_ma):
                prev_close_long_ok = close_prev >= ref_ma
                prev_close_short_ok = close_prev <= ref_ma

        long_entry = long_stack and enter_long_ok and trend_long_ok and macd_long_ok and long_conf and prev_close_long_ok
        short_entry = short_stack and enter_short_ok and trend_short_ok and macd_short_ok and short_conf and cfg.enable_short and prev_close_short_ok

        # exits: MATLAB uses cross of fast vs week, not full stack break
        long_exit_cross = (fast > week)
        short_exit_cross = (week > fast)

        held = 0
        if self.state.pos != 0 and self.state.entry_index is not None:
            held = t - self.state.entry_index
        can_exit = held >= max(0, int(cfg.min_hold_bars))

        macd_exit_long = bool(cfg.use_macd_exit and can_exit and macd_bear)
        macd_exit_short = bool(cfg.use_macd_exit and can_exit and macd_bull)

        prev_close_exit_long = False
        prev_close_exit_short = False
        if cfg.use_prev_close_filter and can_exit and _is_finite(close_prev):
            ref_ma = week if cfg.prev_close_filter_ref == "week" else fast
            if _is_finite(ref_ma):
                prev_close_exit_long = close_prev < ref_ma
                prev_close_exit_short = close_prev > ref_ma

        if self.state.pos == 0:
            if long_entry:
                return 1
            if short_entry:
                return -1
            return 0

        if self.state.pos == 1:
            if can_exit and (long_exit_cross or exit_long_ok or macd_exit_long or prev_close_exit_long):
                return 0
            return 1

        # pos == -1
        if can_exit and (short_exit_cross or exit_short_ok or macd_exit_short or prev_close_exit_short):
            return 0
        return -1

    def _macd_state(self, ctx: PrevContext) -> Tuple[bool, bool]:
        """Return (bull, bear) regime flags."""
        h = ctx.macd_hist_prev
        if not _is_finite(h):
            return False, False
        return h > 0, h < 0

    def _check_confirm_long(self, p: int, conf_n: int) -> bool:
        """Match MATLAB check_confirm_long(p, confN).

        In MATLAB: p = t-1, loop i=(p-confN+1):p and use dm.sma*(i).
        """
        if p - conf_n + 1 < 0:
            return False
        df = self.dm.df
        for i in range(p - conf_n + 1, p + 1):
            w = float(df["smaWeek"].iloc[i])
            f = float(df["smaFast"].iloc[i])
            s = float(df["smaSlow"].iloc[i])
            if not (_is_finite(w) and _is_finite(f) and _is_finite(s)):
                return False
            if not (w > f and f > s):
                return False
        return True

    def _check_confirm_short(self, p: int, conf_n: int) -> bool:
        if p - conf_n + 1 < 0:
            return False
        df = self.dm.df
        for i in range(p - conf_n + 1, p + 1):
            w = float(df["smaWeek"].iloc[i])
            f = float(df["smaFast"].iloc[i])
            s = float(df["smaSlow"].iloc[i])
            if not (_is_finite(w) and _is_finite(f) and _is_finite(s)):
                return False
            if not (s > f and f > w):
                return False
        return True

    def _enter_new(self, t: int, ts: datetime, price: float, target: int, reason: str, ctx: PrevContext) -> None:
        self.state.pos = int(target)
        self.state.units = 1
        self.state.position_frac = self.state.units / self._max_units

        self.state.entry_price = float(price)
        self.state.entry_time = ts
        self.state.entry_index = t

        self.state.hist_max = float("-inf")
        self.state.hist_min = float("inf")
        self.state.best_since_entry = float("nan")
        self.state.worst_since_entry = float("nan")
        self._update_history_extrema(price, price)

        # Execute entry with cash/qty accounting
        side = "BUY" if target == 1 else "SELL"  # short entry is a sell
        self._execute_rebalance(ts, side=side, price=price, reason=reason, target_pos=target)

    def _maybe_add_unit(self, t: int, ts: datetime, price: float) -> None:
        cfg = self.strat_cfg
        st = self.state
        if st.pos == 0 or st.units >= self._max_units:
            return
        if st.entry_price != st.entry_price:
            return

        # episode return measured from the first entry price
        ep_r = float(st.pos) * (price / st.entry_price - 1.0)
        if ep_r >= cfg.pyramid_step_return:
            old_frac = float(st.position_frac)
            st.units += 1
            st.position_frac = st.units / self._max_units
            # Increase exposure by delta fraction (approx.)
            side = "BUY" if st.pos == 1 else "SELL"
            self._execute_rebalance(ts, side=side, price=price, reason="PyramidAdd", target_pos=st.pos, delta_frac=(st.position_frac - old_frac))

    def _exit_all(self, t: int, ts: datetime, price: float, reason: str, is_stop: bool) -> None:
        if self.state.pos == 0:
            return

        # Execute exit with accounting
        side = "SELL" if self.state.pos == 1 else "BUY"  # cover short is BUY
        self._execute_flatten(ts, side=side, price=price, reason=reason)

        # reset position state
        self.state.pos = 0
        self.state.units = 0
        self.state.position_frac = 1.0
        self.state.entry_price = float("nan")
        self.state.entry_time = None
        self.state.entry_index = None
        self.state.hist_max = float("-inf")
        self.state.hist_min = float("inf")
        self.state.best_since_entry = float("nan")
        self.state.worst_since_entry = float("nan")

        self.state.cooldown_until_index = t + max(0, int(self.strat_cfg.cooldown_bars))

    # ---------- execution/accounting ----------

    def _execute_rebalance(
        self,
        ts: datetime,
        side: str,
        price: float,
        reason: str,
        target_pos: int,
        delta_frac: float | None = None,
    ) -> None:
        """Enter / add exposure by trading shares based on allocation fraction."""
        side_u = side.upper()
        rates = self.cost_model.transaction_cost_rates(side_u)

        frac = float(self.state.position_frac)
        if delta_frac is not None:
            frac = max(0.0, float(delta_frac))
        frac = max(0.0, min(1.0, frac))

        eq_val = self._equity_value(price)
        alloc = eq_val * frac
        if not _is_finite(price) or price <= 0 or alloc <= 0:
            return

        qty_abs = int(alloc // float(price))
        if qty_abs <= 0:
            return

        notional = float(qty_abs) * float(price)
        fee = float(rates.fee_rate) * notional
        tax = float(rates.tax_rate) * notional

        if side_u == "BUY":
            # Buy shares (either long entry, or short cover add if ever used)
            self.cash -= (notional + fee + tax)
            self.shares += qty_abs
            qty_signed = qty_abs
        else:
            # Sell shares (either long exit add? or short entry/add)
            self.cash += (notional - fee - tax)
            self.shares -= qty_abs
            qty_signed = -qty_abs

        # Keep state.pos consistent with shares sign
        self.state.pos = int(np.sign(self.shares)) if self.shares != 0 else int(target_pos)

        self.trade_log.append(
            TradeEvent(
                timestamp=ts,
                symbol=self.symbol,
                side=side_u,
                reason=reason,
                price=float(price),
                position_after=int(self.state.pos),
                units_after=int(self.state.units),
                fee_paid=float(fee),
                tax_paid=float(tax),
                qty=int(qty_signed),
                notional=float(notional),
                cash_after=float(self.cash),
                equity_after=float(self._equity_norm(price)),
            )
        )

    def _execute_flatten(self, ts: datetime, side: str, price: float, reason: str) -> None:
        """Close any open position at a given price."""
        if self.shares == 0:
            return
        side_u = side.upper()
        rates = self.cost_model.transaction_cost_rates(side_u)

        qty_abs = abs(int(self.shares))
        notional = float(qty_abs) * float(price)
        fee = float(rates.fee_rate) * notional
        tax = float(rates.tax_rate) * notional

        if side_u == "SELL":
            # sell long holdings
            self.cash += (notional - fee - tax)
            qty_signed = -qty_abs
        else:
            # buy to cover short
            self.cash -= (notional + fee + tax)
            qty_signed = qty_abs

        self.shares = 0

        self.trade_log.append(
            TradeEvent(
                timestamp=ts,
                symbol=self.symbol,
                side=side_u,
                reason=reason,
                price=float(price),
                position_after=0,
                units_after=0,
                fee_paid=float(fee),
                tax_paid=float(tax),
                qty=int(qty_signed),
                notional=float(notional),
                cash_after=float(self.cash),
                equity_after=float(self._equity_norm(price)),
            )
        )
