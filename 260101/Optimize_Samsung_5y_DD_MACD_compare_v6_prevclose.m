%% Optimize Samsung (005930) - MACD OFF vs MACD Allowed (side-by-side)
% 목적:
%   (A) MACD를 강제로 OFF(도입 전과 동일)한 최적화
%   (B) MACD ON/OFF + mode + sizing까지 허용한 최적화
%   -> 두 best 결과를 표로 비교
%
% 전제:
%   - ticker_data_manager(panelFile, ticker) 시그니처 유지
%   - trader_master(초기자본), master.add_trader(dm, enableShort), master.allocate_initial_equal()
%   - backtest_engine(master), eng.set_simulation_window(), eng.optimize_trader_params()

clear; close all; clc;

%% ---- 0) Data file (EDIT THIS) ----
panelFile = "kospi_top100_ohlc_30y.csv";  % <-- 본인 데이터 파일로 변경
ticker    = "005930";                    % 삼성전자

%% ---- 0.5) Backtest window (define early so DM can trim) ----
endDate   = datetime(2024,12,31);
startDate = endDate - calyears(5) + days(1);



%% ---- 1) Build DM / Master / Engine ----
% (속도 최적화) DM 생성 시 백테스트 구간(startDate/endDate)을 함께 전달하면,
% 해당 구간(+워밍업)만 남겨 SMA/ATR/MACD를 계산합니다.
dm = ticker_data_manager(panelFile, ticker, startDate, endDate);

initialCapital = 1e9; % 10억
master = trader_master(initialCapital);
master.add_trader(dm, true);       % enableShort initial (optimizer can override)
master.allocate_initial_equal();   % ✅ initial equity=0 방지

eng = backtest_engine(master);

%% ---- 2) Simulation window: last 5 years (example) ----

% Set simulation window (backward/forward compatible)
if ismethod(eng, "set_simulation_window")
    eng.set_simulation_window(startDate, endDate);
elseif isprop(eng, "StartDate") && isprop(eng, "EndDate")
    eng.StartDate = startDate;
    eng.EndDate   = endDate;
else
    % If your engine version sets the window elsewhere, ignore.
end
fprintf("Optimization window: %s ~ %s\n", datestr(startDate), datestr(endDate));




%% ---- 3) Base search space (same as your existing script) ----
Sbase = struct();

% Separation (SMA5-SMA20) percentage filter + hysteresis
Sbase.SpreadEnterPct = [0.0015 0.0020 0.0030 0.0040 0.0050];
Sbase.SpreadExitPct  = [0.0003 0.0007 0.0010 0.0015];

% ATR-normalized separation (recommended)
Sbase.UseATRFilter   = [true];
Sbase.AtrEnterK      = [0.15 0.25 0.35 0.50 0.70];
Sbase.AtrExitK       = [0.05 0.10 0.20];

% Confirmation / anti-whipsaw
Sbase.ConfirmDays    = [1 2 3];
Sbase.MinHoldDays    = [1 3 5];
Sbase.CooldownDays   = [0 2 5];

% Trend filter options
Sbase.UseLongTrendFilter  = [true];
Sbase.UseShortTrendFilter = [false true];

% Enable/disable short
Sbase.EnableShort    = [false true];

% Stops (coarse ranges)
Sbase.LongDailyStop  = [0.03 0.05 0.07];
Sbase.LongTrailStop  = [0.08 0.10 0.12];
Sbase.ShortDailyStop = [0.02 0.03 0.04];
Sbase.ShortTrailStop = [0.08 0.10 0.12];

% Previous close confirmation filter (choose reference MA)
Sbase.UsePrevCloseFilter = [false true];
Sbase.PrevCloseFilterRef = ["fast" "week"]; % Close(t-1) vs SMA20 or SMA5

%% ---- 4) Add MACD dimensions (allowed-run only) ----
Smacd = Sbase;

% MACD gating / exit / mode
Smacd.UseMACDRegimeFilter = [false true];
Smacd.UseMACDExit         = [false true];
Smacd.MACDSignalMode      = ["hist" "cross"];

% Entry-fixed sizing based on MACD strength
Smacd.UseMACDSizeScaling  = [false true];
Smacd.MACDSizeMin         = [0.25 0.40 0.60];
Smacd.MACDSizeMax         = [0.80 1.00];
Smacd.MACDSizeAtrK        = [0.25 0.50 1.00];

%% ---- 5) Build MACD-OFF search space (force OFF) ----
Soff = Smacd;
Soff.UseMACDRegimeFilter = false;
Soff.UseMACDExit         = false;
Soff.MACDSignalMode      = "hist";  % doesn't matter if filters OFF
Soff.UseMACDSizeScaling  = false;
Soff.MACDSizeMin         = 1.0;     % irrelevant when scaling OFF
Soff.MACDSizeMax         = 1.0;
Soff.MACDSizeAtrK        = 1.0;

%% ---- 6) Optimize settings ----
optArgs = { ...
    "MaxEvals", 500, ...
    "Verbose",  true, ...
    "Seed",     7, ...
    "DDPenalty",0.5, ...
    "UseLogEquity", true ...
};

%% ---- 7) (A) Baseline: MACD forced OFF ----
fprintf("\n=== (A) Optimize: MACD FORCED OFF (baseline) ===\n");
master.allocate_initial_equal();
[bestOff, scoreOff, resOff] = eng.optimize_trader_params(1, Soff, optArgs{:});
disp("==== Best Params (MACD OFF) ====");
disp(bestOff);
fprintf("Best score (OFF): %.5f\n", scoreOff);

resOff = sortrows(resOff, "Score", "descend");
writetable(resOff, "opt_results_samsung_5y_MACD_OFF.xlsx", "Sheet","Results", "FileType","spreadsheet");

%% ---- 8) (B) MACD Allowed (ON/OFF + mode + sizing) ----
fprintf("\n=== (B) Optimize: MACD ALLOWED (ON/OFF + mode + sizing) ===\n");
master.allocate_initial_equal();
[bestOn, scoreOn, resOn] = eng.optimize_trader_params(1, Smacd, optArgs{:});
disp("==== Best Params (MACD ALLOWED) ====");
disp(bestOn);
fprintf("Best score (ALLOWED): %.5f\n", scoreOn);

resOn = sortrows(resOn, "Score", "descend");
writetable(resOn, "opt_results_samsung_5y_MACD_ALLOWED.xlsx", "Sheet","Results", "FileType","spreadsheet");

%% ---- 9) Summary table ----
rowOff = resOff(1,:);
rowOn  = resOn(1,:);

% bestOn MACD usage flags (if fields exist)
useReg = false; useExit = false; useSize = false; modeStr = "hist";
if isfield(bestOn, "UseMACDRegimeFilter"), useReg = logical(bestOn.UseMACDRegimeFilter); end
if isfield(bestOn, "UseMACDExit"),         useExit= logical(bestOn.UseMACDExit); end
if isfield(bestOn, "UseMACDSizeScaling"),  useSize= logical(bestOn.UseMACDSizeScaling); end
if isfield(bestOn, "MACDSignalMode"),      modeStr= string(bestOn.MACDSignalMode); end

summary = table( ...
    ["MACD_OFF"; "MACD_ALLOWED"], ...
    [rowOff.Score; rowOn.Score], ...
    [rowOff.EquityEnd; rowOn.EquityEnd], ...
    [rowOff.TotRet; rowOn.TotRet], ...
    [rowOff.CAGR; rowOn.CAGR], ...
    [rowOff.MaxDD; rowOn.MaxDD], ...
    ["-"; compose("Regime=%d, Exit=%d, Size=%d, Mode=%s", useReg, useExit, useSize, modeStr)], ...
    'VariableNames', ["Run","BestScore","EquityEnd","TotRet","CAGR","MaxDD","MACD_Config"] ...
);

disp("==== Summary (Best vs Best) ====");
disp(summary);

writetable(summary, "opt_summary_samsung_5y_MACD_compare.xlsx", "Sheet","Summary", "FileType","spreadsheet");

fprintf("\nSaved:\n - opt_results_samsung_5y_MACD_OFF.xlsx\n - opt_results_samsung_5y_MACD_ALLOWED.xlsx\n - opt_summary_samsung_5y_MACD_compare.xlsx\n\n");

%% ---- 10) Optional: re-run best ALLOWED and plot/report ----
tr = master.Traders(1);
tr.set_hparams(bestOn);
eng.run();
disp(eng.report());
eng.save_excel("best_run_report_samsung_5y_MACD_ALLOWED.xlsx");
eng.plot();  % if plot is slow, use your patched plot with subsampling options
