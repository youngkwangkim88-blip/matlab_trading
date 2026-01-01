%% Validate_Top5_Samsung.m
% (i) Yearly PnL decomposition
% (ii) Parameter sensitivity around Top-5 candidates (train only)
% (iii) Train/Validation split:
%      Train: 2019-01-01 ~ 2024-12-31
%      Val-A: 2015-01-01 ~ 2018-12-31
%      Val-B: 2025-01-01 ~ 2025-12-31
%
% R2025b compatible. No arguments blocks. All functions closed with end.

clear; clc;

%% ========= USER CONFIG =========
panelFile = "kospi_top100_ohlc_30y.csv";   % <-- change to your actual path
ticker    = "005930";                      % Samsung Electronics
initialCapital = 1e9;                      % 10억

optFile  = "opt_results_samsung_5y.xlsx";  % optimizer output
optSheet = 1;                              % sheet index or name

topK = 5;
DDPenalty = 0.5; % Score = log(EndEquity) - DDPenalty*MaxDD

TRAIN_START = datetime(2019,1,1);
TRAIN_END   = datetime(2024,12,31);
VALA_START  = datetime(2015,1,1);
VALA_END    = datetime(2018,12,31);
VALB_START  = datetime(2025,1,1);
VALB_END    = datetime(2025,12,31);

pctBumps = [0.8, 1.0, 1.2];   % +/-20% (continuous)
confirmBumps = [-1, 0, +1];   % ConfirmDays +/-1

sensParamsContinuous = {'SpreadEnterPct','SpreadExitPct','LongDailyStop','LongTrailStop','ShortDailyStop','ShortTrailStop'};
sensParamsInteger    = {'ConfirmDays'};

outDir = "validation_outputs";
if ~exist(outDir, "dir"); mkdir(outDir); end

%% ========= LOAD OPT RESULTS =========
fprintf("Loading optimization results: %s\n", optFile);
try
    results = readtable(optFile, "Sheet", optSheet);
catch
    results = readtable(optFile);
end

if ~ismember("Score", results.Properties.VariableNames)
    error("Results table must include 'Score' column.");
end
if ~ismember("ParamsJson", results.Properties.VariableNames)
    error("Results table must include 'ParamsJson' column.");
end

results = sortrows(results, "Score", "descend");
K = min(topK, height(results));
top = results(1:K,:);

periodNames = ["Train_2019_2024","ValA_2015_2018","ValB_2025"];
periodStart = [TRAIN_START, VALA_START, VALB_START];
periodEnd   = [TRAIN_END,   VALA_END,   VALB_END];

%% ========= RUN TOP-K ON TRAIN/VAL + YEARLY PNL =========
metricsRows = table();
yearlyPnLAll = table();
eqCurves = cell(K, numel(periodNames));

for i = 1:K
    params = jsondecode(char(top.ParamsJson(i)));

    for p = 1:numel(periodNames)
        s0 = periodStart(p); s1 = periodEnd(p);

        [rep, tr, eqTT] = run_one(panelFile, ticker, initialCapital, params, s0, s1, DDPenalty);
        eqCurves{i,p} = eqTT;

        row = table(i, periodNames(p), s0, s1, rep.Score, rep.EquityEnd, rep.TotRet, rep.CAGR, rep.MaxDD, rep.Trades, rep.Stops, ...
            'VariableNames', {'Candidate','Period','StartDate','EndDate','Score','EquityEnd','TotRet','CAGR','MaxDD','Trades','Stops'});
        metricsRows = [metricsRows; row]; %#ok<AGROW>

        yp = yearly_pnl(tr);
        if ~isempty(yp)
            yp.Candidate = repmat(i, height(yp), 1);
            yp.Period = repmat(periodNames(p), height(yp), 1);
            yearlyPnLAll = [yearlyPnLAll; yp]; %#ok<AGROW>
        end
    end
end

metricsFile = fullfile(outDir, "top5_train_val_metrics.xlsx");
writetable(metricsRows, metricsFile, "Sheet", "Metrics");
if ~isempty(yearlyPnLAll)
    writetable(yearlyPnLAll, metricsFile, "Sheet", "YearlyPnL");
end
fprintf("Saved metrics: %s\n", metricsFile);

%% ========= SENSITIVITY (TOP-K, TRAIN ONLY) =========
sensAll = table();

for i = 1:K
    baseParams = jsondecode(char(top.ParamsJson(i)));

    % Continuous params: +/- 20%
    for sp = 1:numel(sensParamsContinuous)
        key = sensParamsContinuous{sp};
        if ~isfield(baseParams, key); continue; end
        baseVal = baseParams.(key);
        if ~isnumeric(baseVal) || ~isscalar(baseVal); continue; end

        for m = 1:numel(pctBumps)
            bump = pctBumps(m);
            p2 = baseParams;
            p2.(key) = clamp_param(key, baseVal * bump);

            rep = run_one(panelFile, ticker, initialCapital, p2, TRAIN_START, TRAIN_END, DDPenalty);

            srow = table(i, string(key), baseVal, p2.(key), bump, rep.Score, rep.EquityEnd, rep.MaxDD, rep.Trades, ...
                'VariableNames', {'Candidate','Param','BaseValue','TestValue','Multiplier','Score','EquityEnd','MaxDD','Trades'});
            sensAll = [sensAll; srow]; %#ok<AGROW>
        end
    end

    % Integer params: ConfirmDays +/- 1
    for sp = 1:numel(sensParamsInteger)
        key = sensParamsInteger{sp};
        if ~isfield(baseParams, key); continue; end
        baseVal = baseParams.(key);
        if ~isnumeric(baseVal) || ~isscalar(baseVal); continue; end

        for d = 1:numel(confirmBumps)
            dd = confirmBumps(d);
            p2 = baseParams;
            p2.(key) = max(1, round(baseVal + dd));

            rep = run_one(panelFile, ticker, initialCapital, p2, TRAIN_START, TRAIN_END, DDPenalty);

            srow = table(i, string(key), baseVal, p2.(key), dd, rep.Score, rep.EquityEnd, rep.MaxDD, rep.Trades, ...
                'VariableNames', {'Candidate','Param','BaseValue','TestValue','Multiplier','Score','EquityEnd','MaxDD','Trades'});
            sensAll = [sensAll; srow]; %#ok<AGROW>
        end
    end
end

sensFile = fullfile(outDir, "top5_param_sensitivity_train.xlsx");
writetable(sensAll, sensFile, "Sheet", "Sensitivity");
fprintf("Saved sensitivity: %s\n", sensFile);

%% ========= OPTIONAL: Overlay equity curves (train & 2025) =========
try
    plot_overlay_eq(eqCurves, periodNames, outDir);
catch ME
    warning("Overlay plot failed: %s", ME.message);
end

fprintf("Validation done.\n");

%% ======================= LOCAL FUNCTIONS =======================

function [rep, tr, eqTT] = run_one(panelFile, ticker, initialCapital, params, startDate, endDate, ddPenalty)
% Build fresh objects, apply params, run, compute metrics.
    master = trader_master(initialCapital);
    dm = ticker_data_manager(panelFile, ticker);
    master.add_trader(dm, true);
    master.allocate_initial_equal();

    eng = backtest_engine(master);
    eng.StartDate = startDate;
    eng.EndDate   = endDate;

    tr = master.Traders(1);
    apply_params_to_trader(tr, params);

    eng.run();

    eqTT = tr.EqCurve;
    eq = eqTT.Equity;
    dt = eqTT.Properties.RowTimes;

    rep = struct();
    rep.EquityEnd = eq(end);
    rep.TotRet = eq(end)/eq(1) - 1;
    rep.CAGR = compute_cagr(dt, eq);
    rep.MaxDD = compute_maxdd(eq);
    rep.Trades = height(tr.TradeLog);
    rep.Stops  = height(tr.StopLog);
    rep.Score  = log(max(rep.EquityEnd, 1)) - ddPenalty * rep.MaxDD;
end

function apply_params_to_trader(tr, params)
% Prefer set_hparams if available.
    if ismethod(tr, "set_hparams")
        tr.set_hparams(params);
        return;
    end
    fns = fieldnames(params);
    for k = 1:numel(fns)
        fn = fns{k};
        if isprop(tr, fn)
            try
                tr.(fn) = params.(fn);
            catch
                % ignore type mismatches
            end
        end
    end
end

function cagr = compute_cagr(dt, eq)
    if numel(eq) < 2
        cagr = NaN; return;
    end
    nYears = days(dt(end) - dt(1)) / 365.25;
    if nYears <= 0
        cagr = NaN; return;
    end
    cagr = (eq(end)/eq(1))^(1/nYears) - 1;
end

function mdd = compute_maxdd(eq)
    peak = eq(1);
    mdd = 0;
    for i = 1:numel(eq)
        if eq(i) > peak
            peak = eq(i);
        end
        dd = 1 - eq(i)/peak;
        if dd > mdd
            mdd = dd;
        end
    end
end

function yp = yearly_pnl(tr)
% Yearly realized PnL using EXIT actions and EquityBefore/After if present.
    TL = tr.TradeLog;
    yp = table();
    if isempty(TL); return; end
    if ~ismember("Action", TL.Properties.VariableNames) || ~ismember("Time", TL.Properties.VariableNames)
        return;
    end
    isExit = (TL.Action == "EXIT");
    if ~any(isExit); return; end
    TLe = TL(isExit,:);

    if ismember("EquityBefore", TLe.Properties.VariableNames) && ismember("EquityAfter", TLe.Properties.VariableNames)
        pnl = TLe.EquityAfter - TLe.EquityBefore;
    elseif ismember("PnL", TLe.Properties.VariableNames)
        pnl = TLe.PnL;
    else
        return;
    end

    yy = year(TLe.Time);
    tmp = table(yy, pnl, 'VariableNames', {'Year','PnL'});
    yp = groupsummary(tmp, "Year", "sum", "PnL");
    yp.Properties.VariableNames{'sum_PnL'} = 'PnL_Sum';
end

function v = clamp_param(key, v)
% Reasonable bounds
    if contains(key, "Pct")
        v = min(max(v, 0), 0.05); % 0~5%
    end
    if contains(key, "Stop")
        v = min(max(v, 0.001), 0.5); % 0.1%~50%
    end
end

function plot_overlay_eq(eqCurves, periodNames, outDir)
    K = size(eqCurves,1);

    % Train (period 1)
    figure('Color','w','Name','TopK Equity Overlay - Train'); hold on; grid on;
    for i=1:K
        tt = eqCurves{i,1};
        plot(tt.Properties.RowTimes, tt.Equity, 'LineWidth', 1.2);
    end
    title("TopK Equity Overlay - " + periodNames(1));
    legend(compose("Cand %d", 1:K), 'Location','best');
    hold off;
    exportgraphics(gcf, fullfile(outDir, "topK_equity_overlay_train.png"));

    % 2025 (period 3)
    figure('Color','w','Name','TopK Equity Overlay - 2025'); hold on; grid on;
    for i=1:K
        tt = eqCurves{i,3};
        plot(tt.Properties.RowTimes, tt.Equity, 'LineWidth', 1.2);
    end
    title("TopK Equity Overlay - " + periodNames(3));
    legend(compose("Cand %d", 1:K), 'Location','best');
    hold off;
    exportgraphics(gcf, fullfile(outDir, "topK_equity_overlay_2025.png"));
end
