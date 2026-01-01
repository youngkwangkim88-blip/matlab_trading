%% Optimize Samsung Electronics (005930) MA-trend hyperparameters (last 5 years)
% Requires updated classes:
%   - ticker_data_manager.m  (ATR-enabled)
%   - ticker_trader.m        (hyperparams + set_hparams + filters)
%   - backtest_engine.m      (optimize_trader_params added)
%
% Usage:
%   1) Put your panel CSV file path below (must include columns: Date,Ticker,Open,High,Low,Close,Name(optional))
%   2) Run this script.

clear; close all; clc;

%% ---- 0) Data file (EDIT THIS) ----
panelFile = "kospi_top100_ohlc_30y.csv";  % <-- change to your actual file path
ticker    = "005930";                    % Samsung Electronics

%% ---- 1) Build DM / Master / Engine ----
dm = ticker_data_manager(panelFile, ticker);

master = trader_master(1e9);  % 10억
master.add_trader(dm, true);  % enableShort initial (optimizer can override)


master.allocate_initial_equal();  % IMPORTANT: allocate initial capital before optimization
eng = backtest_engine(master);

%% ---- 2) Simulation window: last 5 years ending 2024-12-31 by default ----
% (If you want "recent 5 years" up to today, set endDate=datetime("today"))
endDate   = datetime(2024,12,31);
startDate = endDate - calyears(5) + days(1);
eng.set_simulation_window(startDate, endDate);

fprintf("Optimization window: %s ~ %s\n", datestr(startDate), datestr(endDate));

%% ---- 3) Define search space (random sampling if too large) ----
S = struct();

% Separation (SMA5-SMA20) percentage filter + hysteresis
S.SpreadEnterPct = [0.0015 0.0020 0.0030 0.0040 0.0050];
S.SpreadExitPct  = [0.0003 0.0007 0.0010 0.0015];

% ATR-normalized separation (recommended)
S.UseATRFilter   = [true];
S.AtrEnterK      = [0.15 0.25 0.35 0.50 0.70];
S.AtrExitK       = [0.05 0.10 0.20];

% Confirmation / anti-whipsaw
S.ConfirmDays    = [1 2 3];
S.MinHoldDays    = [1 3 5];
S.CooldownDays   = [0 2 5];

% Trend filter options
S.UseLongTrendFilter  = [true];
S.UseShortTrendFilter = [false true];

% Enable/disable short
S.EnableShort    = [false true];

% Stops (coarse ranges)
S.LongDailyStop  = [0.03 0.05 0.07];
S.LongTrailStop  = [0.08 0.10 0.12];
S.ShortDailyStop = [0.02 0.03 0.04];
S.ShortTrailStop = [0.08 0.10 0.12];

%% ---- 4) Optimize ----
[bestParams, bestScore, results] = eng.optimize_trader_params(1, S, ...
    "MaxEvals", 250, "Verbose", true, "Seed", 7, "DDPenalty", 0.5, "UseLogEquity", true);

disp("==== Best Params (struct) ====");
disp(bestParams);
fprintf("Best score: %.5f\n", bestScore);

% Save optimization results
results = sortrows(results, "Score", "descend");
writetable(results, "opt_results_samsung_5y.xlsx", "Sheet", "Results", "FileType","spreadsheet");

%% ---- 5) Re-run best and generate a report ----
tr = master.Traders(1);
tr.set_hparams(bestParams);

eng.run();

rep = eng.report();
disp(rep);

eng.save_excel("best_run_report_samsung_5y.xlsx");
%%
% Optional visualization
% eng.plot();

%% ===== Plot Top-5 candidates =====
% Assumes:
% - results table exists and contains columns: Score, ParamsJson (or ParamsStruct), etc.
% - you can rebuild master/engine for each trial (recommended to avoid state carry-over)
% - panelFile, StartDate/EndDate, ticker, initialCapital are defined in your script

topK = 5;

% Sort by Score descending and take Top-K
resultsSorted = sortrows(results, "Score", "descend");
K = min(topK, height(resultsSorted));
fprintf("\n[Plot] Top-%d candidates will be rerun and plotted...\n", K);

outDir = "top5_plots";
if ~exist(outDir, "dir"); mkdir(outDir); end

for r = 1:K
    row = resultsSorted(r,:);

    % ---- Decode params ----
    if ismember("ParamsStruct", resultsSorted.Properties.VariableNames) && ~isempty(row.ParamsStruct{1})
        P = row.ParamsStruct{1};  % already a struct in a cell
    else
        % ParamsJson is assumed to be JSON string
        P = jsondecode(char(row.ParamsJson));
    end

    fprintf("\n=== Top-%d ===\n", r);
    disp(P);

    % ---- Build fresh objects (recommended) ----
    master = trader_master(1e9); % 10억 (필요시 스크립트 변수를 사용)
    dm = ticker_data_manager(panelFile, "005930"); % 삼성전자
    master.add_trader(dm, true);  % enableShort initial
    master.allocate_initial_equal();

    eng = backtest_engine(master);

    % set simulation window (최근 5년: 예시)
    eng.StartDate = datetime(2019,1,1);
    eng.EndDate   = datetime(2024,12,31);

    % (옵션) 거래비용 파라미터도 여기서 동일하게 세팅
    % eng.Commission = ...; eng.Slippage = ...; eng.STT_2024 = ...; eng.ShortBorrowAnnual = ...;

    % ---- Apply hyper-params to trader ----
    tr = master.Traders(1);
    if ismethod(tr, "set_hparams")
        tr.set_hparams(P);
    else
        % fallback: set fields manually
        fns = fieldnames(P);
        for k = 1:numel(fns)
            fn = fns{k};
            if isprop(tr, fn)
                tr.(fn) = P.(fn);
            end
        end
    end

    % ---- Run backtest ----
    eng.run();

    % ---- Report ----
    rep = eng.report();
    disp(rep);

    % ---- Plot (interactive) ----
    eng.plot();  % 현재 plot 함수가 창을 생성한다고 가정

    % ---- Save figure(s) ----
    % eng.plot()이 종목별로 figure를 만들면, 현재 열린 figure를 저장하는 방식이 제일 간단합니다.
    fig = gcf;
    figName = sprintf("%s/Top%02d_Score%.4f.png", outDir, r, row.Score);
    exportgraphics(fig, figName);

    % ---- Save per-run excel report (optional) ----
    xlsxName = sprintf("%s/Top%02d_report.xlsx", outDir, r);
    eng.save_excel(xlsxName);
end

fprintf("\nDone. Plots & reports saved under folder: %s\n", outDir);
