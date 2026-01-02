# Step 1 prototype (Python)

This folder contains a minimal, MATLAB-compatible backtest prototype for **Step 1**:
- single-symbol backtest (daily or intraday bars)
- signal uses **previous-bar indicators** and executes at **Open(t)** (no lookahead)
- KRX-style costs: STT (0.2% on sells) and short borrow cost (annual 4% -> daily)
- optional forced cover for shorts after 90 calendar days

Run examples:
```bash
python -m scripts.run_step1_single_ticker --symbol 005930.KS --start 2024-01-01 --end 2025-12-31
python -m scripts.run_step1_single_ticker --csv ../005930_intraday_2h_20251101_20260101.csv
```

Outputs are written under `./outputs/`.
