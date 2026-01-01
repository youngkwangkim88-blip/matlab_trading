%% Optimize Samsung (005930) - Portfolio Architecture (MACD OFF vs MACD Allowed)
% 신규 portfolio_master / portfolio_backtest_engine 기반 단일 종목 최적화.
%
% 신뢰도 포인트
%  - Trades는 "trader 로그"가 아니라 "portfolio 실제 체결(TradeLog)" 기준
%  - 체결이 0이면 score를 -Inf로 처리(ln(InitialCapital) 같은 착시 제거)
%
% 출력 파일
%  - opt_results_samsung_5y_MACD_OFF_portfolio.xlsx
%  - opt_results_samsung_5y_MACD_ALLOWED_portfolio.xlsx
%  - opt_summary_samsung_5y_MACD_compare_portfolio.xlsx

clear; close all; clc;

%% ---- 0) Data ----
panelFile = "kospi_top100_ohlc_30y.csv";  % <-- 변경
symbol    = "005930";                    % 삼성전자

%% ---- 1) Window (5y) ----
endDate   = datetime(2024,12,31);
startDate = endDate - calyears(5) + days(1);

initialCapital = 1e9;

%% ---- 2) Data manager (trim in constructor) ----
dm = ticker_data_manager(panelFile, symbol, startDate, endDate);

%% ---- 3) Instrument spec (KRX stock baseline) ----
specBase = instrument_spec(symbol, "KRX_STOCK", ...
    "Multiplier", 1.0, ...
    "AllowShort", true, ...
    "MaxNotionalFrac", 1.0, ...
    "FeeModel", fee_model_rate(0.00015, 0.00010), ...
    "TaxModel", tax_model_krx_stt(0.0018, 0.0015), ...
    "MarginModel", margin_model_simple(0.0, 0.50, 0.30), ...
    "BorrowRateAnnual", 0.04);

%% ---- 4) Search spaces ----
Sbase = struct();
Sbase.SpreadEnterPct = [0.0015 0.0020 0.0030 0.0040 0.0050];
Sbase.SpreadExitPct  = [0.0003 0.0007 0.0010 0.0015];

Sbase.UseATRFilter   = [true];
Sbase.AtrEnterK      = [0.15 0.25 0.35 0.50 0.70];
Sbase.AtrExitK       = [0.05 0.10 0.20];

Sbase.ConfirmDays    = [1 2 3];
Sbase.MinHoldDays    = [1 3 5];
Sbase.CooldownDays   = [0 2 5];

Sbase.UseLongTrendFilter  = [true];
Sbase.UseShortTrendFilter = [false true];

Sbase.EnableShort    = [false true];

Sbase.LongDailyStop  = [0.03 0.05 0.07];
Sbase.LongTrailStop  = [0.08 0.10 0.12];
Sbase.ShortDailyStop = [0.02 0.03 0.04];
Sbase.ShortTrailStop = [0.08 0.10 0.12];

Sbase.UsePrevCloseFilter = [false true];
Sbase.PrevCloseFilterRef = ["fast" "week"]; % Close(t-1) vs SMA20 or SMA5

Smacd = Sbase;
Smacd.UseMACDRegimeFilter = [false true];
Smacd.UseMACDExit         = [false true];
Smacd.MACDSignalMode      = ["hist" "cross"];

Smacd.UseMACDSizeScaling  = [false true];
Smacd.MACDSizeMin         = [0.25 0.40 0.60];
Smacd.MACDSizeMax         = [0.80 1.00];
Smacd.MACDSizeAtrK        = [0.25 0.50 1.00];

Soff = Smacd;
Soff.UseMACDRegimeFilter = false;
Soff.UseMACDExit         = false;
Soff.MACDSignalMode      = "hist";
Soff.UseMACDSizeScaling  = false;
Soff.MACDSizeMin         = 1.0;
Soff.MACDSizeMax         = 1.0;
Soff.MACDSizeAtrK        = 1.0;

%% ---- 5) Optimizer settings ----
MaxEvals   = 500;
Seed       = 7;
DDPenalty  = 0.5;
VerboseEvery = 25;
UseLogEquity = true;

rng(Seed);

%% ---- 6) Run A: MACD forced OFF ----
fprintf("\n=== (A) Optimize: MACD FORCED OFF (Portfolio) ===\n");
[bestOff, resOff] = optimize_random(dm, specBase, Soff, startDate, endDate, initialCapital, ...
    MaxEvals, DDPenalty, UseLogEquity, VerboseEvery);

resOff = sortrows(resOff, "Score", "descend");
if ~isempty(resOff)
    bestOff = jsondecode(resOff.ParamsJson{1});
end
writetable(resOff, "opt_results_samsung_5y_MACD_OFF_portfolio.xlsx", "Sheet","Results", "FileType","spreadsheet");

%% ---- 7) Run B: MACD allowed ----
fprintf("\n=== (B) Optimize: MACD ALLOWED (Portfolio) ===\n");
[bestOn, resOn] = optimize_random(dm, specBase, Smacd, startDate, endDate, initialCapital, ...
    MaxEvals, DDPenalty, UseLogEquity, VerboseEvery);

resOn = sortrows(resOn, "Score", "descend");
if ~isempty(resOn)
    bestOn = jsondecode(resOn.ParamsJson{1});
end
writetable(resOn, "opt_results_samsung_5y_MACD_ALLOWED_portfolio.xlsx", "Sheet","Results", "FileType","spreadsheet");

%% ---- 8) Summary ----
rowOff = resOff(1,:);
rowOn  = resOn(1,:);

summary = table( ...
    ["MACD_OFF"; "MACD_ALLOWED"], ...
    [rowOff.Score; rowOn.Score], ...
    [rowOff.EquityEnd; rowOn.EquityEnd], ...
    [rowOff.MaxDD; rowOn.MaxDD], ...
    [rowOff.TradesPf; rowOn.TradesPf], ...
    [rowOff.TradesTr; rowOn.TradesTr], ...
    'VariableNames', ["Run","BestScore","EquityEnd","MaxDD","TradesPf","TradesTr"]);

disp(summary);
writetable(summary, "opt_summary_samsung_5y_MACD_compare_portfolio.xlsx", "Sheet","Summary", "FileType","spreadsheet");

fprintf("\nSaved:\n - opt_results_samsung_5y_MACD_OFF_portfolio.xlsx\n - opt_results_samsung_5y_MACD_ALLOWED_portfolio.xlsx\n - opt_summary_samsung_5y_MACD_compare_portfolio.xlsx\n\n");

%% ================= Local functions =================

function [bestParams, resTable] = optimize_random(dm, specBase, Sspace, startDate, endDate, initialCapital, MaxEvals, DDPenalty, UseLogEquity, VerboseEvery)
    bestParams = struct();
    bestScore  = -Inf;

    resTable = table('Size',[0 9], ...
        'VariableTypes',["double","double","double","double","double","double","double","double","string"], ...
        'VariableNames',["Eval","Score","EquityEnd","TotRet","CAGR","MaxDD","TradesPf","TradesTr","ParamsJson"]);

    for e = 1:MaxEvals
        hp = sample_from_space(Sspace);

        % Build a fresh portfolio/master/engine each eval (신뢰도 우선)
        pm = portfolio_master(initialCapital);

        spec = specBase;
        if isfield(hp,'EnableShort')
            spec.AllowShort = logical(hp.EnableShort);
        end

        tr = ticker_trader(dm, 0, spec.AllowShort);
        if ismethod(tr,'enable_external_accounting')
            tr.enable_external_accounting(true);
        end
        tr.set_logging(false, true, true);
        tr.set_hparams(hp);

        pm.add_instrument(dm, spec, tr);

        eng = portfolio_backtest_engine(pm);
        eng.StartDate = startDate;
        eng.EndDate   = endDate;
        eng.ValuationMode = 'CLOSE';
        eng.UseDynamicSizing = true;
        eng.UseEntryPositionFrac = true;
        eng.EnableSanityWarnings = false;
        eng.ResetTradersEachRun = true;

        eng.run();

        pf = pm.Portfolio;
        tradesPf = height(pf.TradeLog);
        % trader TradeLog에는 REJECT(거절/0수량)도 포함될 수 있으므로, 실행된 거래만 카운트
        tradesTrExec = 0; tradesTrReject = 0;
        if ~isempty(tr.TradeLog) && height(tr.TradeLog) > 0
            act = upper(string(tr.TradeLog.Action));
            tradesTrExec   = sum(act == "ENTER" | act == "EXIT");
            tradesTrReject = sum(act == "REJECT");
        end
        tradesTr = tradesTrExec;

        if isempty(pf.EquityCurve)
            eqEnd = initialCapital;
            maxDD = 0;
            totRet = 0;
            cagr = 0;
        else
            eqSeries = pf.EquityCurve.Equity;
            tSeries  = pf.EquityCurve.Properties.RowTimes;
            eq0 = eqSeries(1);
            eqEnd = eqSeries(end);

            totRet = eqEnd/eq0 - 1;
            nYears = max(days(tSeries(end)-tSeries(1))/365.25, eps);
            cagr = (eqEnd/eq0)^(1/nYears) - 1;

            % Max Drawdown
            peak = -Inf;
            dd = zeros(size(eqSeries));
            for i=1:numel(eqSeries)
                peak = max(peak, eqSeries(i));
                if peak > 0
                    dd(i) = 1 - eqSeries(i)/peak;
                else
                    dd(i) = 0;
                end
            end
            maxDD = max(dd);
        end

        % 신뢰도: 포트폴리오 체결이 0이면 score 무효
        if tradesPf <= 0
            score = -Inf;
        else
            if UseLogEquity
                score = log(max(eqEnd, realmin));
            else
                score = eqEnd;
            end
            score = score - DDPenalty * maxDD;
        end

        pj = jsonencode(hp);
        resTable = [resTable; {double(e), double(score), double(eqEnd), double(totRet), double(cagr), double(maxDD), double(tradesPf), double(tradesTr), string(pj)}]; %#ok<AGROW>

        if score > bestScore
            bestScore = score;
            bestParams = hp;
            fprintf("[Best] eval=%d score=%.6f endEq=%.0f MaxDD=%.4f TradesPf=%d TradesTrExec=%d\n", e, score, eqEnd, maxDD, tradesPf, tradesTrExec);
        elseif mod(e, VerboseEvery) == 0
            fprintf("eval=%d score=%.6f endEq=%.0f MaxDD=%.4f TradesPf=%d TradesTrExec=%d\n", e, score, eqEnd, maxDD, tradesPf, tradesTrExec);
        end

        % 디버그: trader는 거래가 있는데 포트폴리오 체결이 0이면 바로 표시
        if tradesTrExec > 0 && tradesPf == 0 && mod(e, VerboseEvery) == 0
            fprintf("  [WARN] traderExec=%d traderReject=%d but portfolio TradeLog=0 (likely all rejected or sizing=0)\n", tradesTrExec, tradesTrReject);
        end
    end
end

function hp = sample_from_space(S)
    hp = struct();
    fn = fieldnames(S);
    for i=1:numel(fn)
        f = fn{i};
        v = S.(f);
        if iscell(v)
            idx = randi(numel(v));
            hp.(f) = v{idx};
        elseif isstring(v) || ischar(v)
            % string array or char
            if ischar(v)
                hp.(f) = v;
            else
                idx = randi(numel(v));
                hp.(f) = v(idx);
            end
        else
            % numeric/logical array
            idx = randi(numel(v));
            hp.(f) = v(idx);
        end
    end
end
