"""Data providers (yfinance / CSV) and a standardized OHLCV schema."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import pandas as pd


@dataclass(frozen=True)
class OhlcvFrame:
    """Standard OHLCV dataframe wrapper."""

    df: pd.DataFrame  # columns: Open, High, Low, Close, Volume; index: datetime (tz-aware preferred)
    symbol: str


def _standardize_ohlcv_columns(df: pd.DataFrame) -> pd.DataFrame:
    # yfinance can return MultiIndex columns depending on options/version.
    # We standardize to a simple 1-level column index.
    if isinstance(df.columns, pd.MultiIndex):
        df = df.copy()
        # Common yfinance layout: (field, ticker)
        if df.columns.nlevels >= 2:
            tickers = list(dict.fromkeys(df.columns.get_level_values(-1)))
            if len(tickers) == 1:
                # single ticker → drop ticker level
                df.columns = df.columns.get_level_values(0)
            else:
                # multiple tickers → keep only the first ticker's fields
                df = df.xs(tickers[0], axis=1, level=-1, drop_level=True)

    rename_map = {}
    for col in df.columns:
        c = str(col).strip()
        if c.lower() in {"open"}:
            rename_map[col] = "Open"
        elif c.lower() in {"high"}:
            rename_map[col] = "High"
        elif c.lower() in {"low"}:
            rename_map[col] = "Low"
        elif c.lower() in {"close"}:
            rename_map[col] = "Close"
        elif c.lower() in {"adj close", "adjclose"}:
            # Keep adjusted close separate to avoid duplicate "Close" columns.
            rename_map[col] = "AdjClose"
        elif c.lower() in {"volume"}:
            rename_map[col] = "Volume"
    df = df.rename(columns=rename_map).copy()

    # If provider only has AdjClose, use it as Close.
    if "Close" not in df.columns and "AdjClose" in df.columns:
        df = df.rename(columns={"AdjClose": "Close"})

    # If both Close and AdjClose exist, prefer Close and drop AdjClose.
    if "Close" in df.columns and "AdjClose" in df.columns:
        df = df.drop(columns=["AdjClose"])

    required = ["Open", "High", "Low", "Close", "Volume"]
    missing = [c for c in required if c not in df.columns]
    if missing:
        raise ValueError(f"Missing required OHLCV columns: {missing}")

    df = df[required].astype(float)
    df = df[~df.index.duplicated(keep="last")].sort_index()
    return df


class YfinanceProvider:
    """Fetch data from yfinance.

    Notes:
    - intraday (interval < 1d) has a limited lookback; keep Step-1 daily by default.
    """

    def fetch(
        self,
        symbol: str,
        start: str,
        end: str,
        interval: str = "1d",
        auto_adjust: bool = False,
    ) -> OhlcvFrame:
        import yfinance as yf  # local import to keep dependency optional in some environments

        df = yf.download(
            tickers=symbol,
            start=start,
            end=end,
            interval=interval,
            auto_adjust=auto_adjust,
            progress=False,
        )
        if df is None or len(df) == 0:
            raise RuntimeError(f"yfinance returned empty data for symbol={symbol}")

        # yfinance uses column names: Open High Low Close Adj Close Volume
        df = _standardize_ohlcv_columns(df)
        return OhlcvFrame(df=df, symbol=symbol)


class CsvProvider:
    """Load OHLCV data from a CSV file."""

    def fetch(self, csv_path: str | Path, symbol: str, datetime_col: str = "Date") -> OhlcvFrame:
        path = Path(csv_path)
        if not path.exists():
            raise FileNotFoundError(str(path))

        df = pd.read_csv(path)
        if datetime_col not in df.columns:
            # try common alternatives
            for cand in ["Datetime", "datetime", "timestamp", "Time", "time"]:
                if cand in df.columns:
                    datetime_col = cand
                    break

        if datetime_col not in df.columns:
            raise ValueError(f"CSV must contain a datetime column. Tried '{datetime_col}' and common aliases.")

        df[datetime_col] = pd.to_datetime(df[datetime_col])
        df = df.set_index(datetime_col).sort_index()

        df = _standardize_ohlcv_columns(df)
        return OhlcvFrame(df=df, symbol=symbol)


class PanelCsvProvider:
    """Load a panel OHLC CSV in the format: Date,Ticker,...,Open,High,Low,Close,(Volume optional)

    The uploaded panel file (kospi_top100_ohlc_30y.csv) matches this style.
    """

    def fetch(
        self,
        panel_csv_path: str | Path,
        symbol: str,
        start: str | None = None,
        end: str | None = None,
    ) -> OhlcvFrame:
        panel_csv_path = Path(panel_csv_path)
        df = pd.read_csv(panel_csv_path)
        # Robust column naming
        cols = {c.lower(): c for c in df.columns}
        date_col = cols.get("date") or cols.get("time")
        ticker_col = cols.get("ticker") or cols.get("symbol")
        if date_col is None or ticker_col is None:
            raise ValueError("Panel CSV must have Date and Ticker columns.")

        df[date_col] = pd.to_datetime(df[date_col])
        sym = str(symbol)
        sym = sym.split(".")[0]
        sym_norm = sym.lstrip("0")
        # Panel ticker may be int-like (e.g., 5930). Match by normalized string.
        df[ticker_col] = df[ticker_col].astype(str).str.strip()
        df = df[df[ticker_col].str.lstrip("0") == sym_norm]
        if start:
            df = df[df[date_col] >= pd.to_datetime(start)]
        if end:
            df = df[df[date_col] <= pd.to_datetime(end)]

        # pick OHLC columns
        def pick(name):
            return cols.get(name.lower())
        o = pick("open"); h = pick("high"); l = pick("low"); c = pick("close")
        v = pick("volume")
        if not all([o, h, l, c]):
            raise ValueError("Panel CSV must contain Open/High/Low/Close columns.")
        out = df[[date_col, o, h, l, c] + ([v] if v else [])].copy()
        out = out.rename(columns={date_col: "Date", o: "Open", h: "High", l: "Low", c: "Close"})
        if v:
            out = out.rename(columns={v: "Volume"})
        else:
            out["Volume"] = 0.0
        out = out.set_index("Date").sort_index()
        out = out.astype(float)
        out = out[~out.index.duplicated(keep="last")]
        out = out[["Open", "High", "Low", "Close", "Volume"]]
        return OhlcvFrame(df=out, symbol=symbol)
