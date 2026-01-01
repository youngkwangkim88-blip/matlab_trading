%% Optimize Samsung (005930) - NEW ARCH (Portfolio) : MACD OFF vs MACD Allowed
% 목적:
%   (A) MACD를 강제로 OFF(도입 전과 동일)한 최적화
%   (B) MACD ON/OFF + mode + sizing까지 허용한 최적화
%   -> 두 best 결과를 표로 비교
%
% 신규 아키텍처(Portfolio) 기준으로, 기존 backtest_engine.optimize_trader_params()에
% 의존하지 않고 스크립트 내부에서 "랜덤 서치" 형태로 동일한 역할을 수행합니다.
%
% 전제(최소):
%   - ticker_data_manager(panelFile, ticker, startDate, endDate)
%   - ticker_trader + set_hparams(params)
%   - portfolio_master(initialCapital) + add_instrument(dm, spec, trader)
%   - portfolio_backtest_engine(portfolio_master) + run()
%
% NOTE:
%   - 결과 파일 포맷은 Validate_Top5_Samsung(신규 아키텍처 버전)에서 그대로 읽을 수 있도록
%     Score / ParamsJson 컬럼을 포함합니다.

clear; close all; clc;

%% ---- 0) Data file (EDIT THIS) ----
panelFile = "kospi_top100_ohlc_30y.csv";  % <-- 본인 데이터 파일로 변경
ticker    = "005930";                    % 삼성전자

%% ---- 0.5) Backtest window ----
endDate   = datetime(2024,12,31);
startDate = endDate - calyears(5) + days(1);

initialCapital = 1e9; % 10억

%% ---- 1) Search Space (기존 스크립트 유지) ----
Sbase = struct();

% Separation (SMA5-SMA20) percentage filter + hysteresis
Sbase.SpreadEnterPct = [0.0015 0.0020 0.0030 0.0040 0.0050];
Sbase.SpreadExitPct  = [0.0003 0.0007 0.0010 0.0015];

% ATR-normalized separation
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

%% ---- 2) Add MACD dimensions (allowed-run only) ----
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

%% ---- 3) MACD-OFF search space (force OFF) ----
Soff = Smacd;
Soff.UseMACDRegimeFilter = false;
Soff.UseMACDExit         = false;
Soff.MACDSignalMode      = "hist";  % doesn't matter if filters OFF
Soff.UseMACDSizeScaling  = false;
Soff.MACDSizeMin         = 1.0;
Soff.MACDSizeMax         = 1.0;
Soff.MACDSizeAtrK        = 1.0;

%% ---- 4) Optimize settings ----
MaxEvals      = 500;
Seed          = 7;
DDPenalty     = 0.5;
UseLogEquity  = true;
Verbose       = true;

rng(Seed);

%% ---- 5) Instrument Spec (KRX 주식 기본값) ----
% 아래는 "신규 아키텍처"의 비용/세금/증거금 모델을 사용합니다.
% 사용 중인 클래스명이 다를 수 있으니, 필요하면 여기만 본인 환경에 맞춰 조정하세요.

spec = build_default_krx_equity_spec(ticker);

%% ---- 6) Run (A) MACD OFF ----
fprintf("\n=== (A) Optimize: MACD FORCED OFF (Portfolio) ===\n");
[bestOff, scoreOff, resOff] = optimize_random(panelFile, ticker, initialCapital, Soff, spec, startDate, endDate, ...
    MaxEvals, DDPenalty, UseLogEquity, Verbose);

fprintf("Best score (OFF): %.6f\n", scoreOff);
disp(bestOff);

resOff = sortrows(resOff, "Score", "descend");
writetable(resOff, "opt_results_samsung_5y_MACD_OFF.xlsx", "Sheet","Results", "FileType","spreadsheet");

%% ---- 7) Run (B) MACD Allowed ----
fprintf("\n=== (B) Optimize: MACD ALLOWED (Portfolio) ===\n");
[bestOn, scoreOn, resOn] = optimize_random(panelFile, ticker, initialCapital, Smacd, spec, startDate, endDate, ...
    MaxEvals, DDPenalty, UseLogEquity, Verbose);

fprintf("Best score (ALLOWED): %.6f\n", scoreOn);
disp(bestOn);

resOn = sortrows(resOn, "Score", "descend");
writetable(resOn, "opt_results_samsung_5y_MACD_ALLOWED.xlsx", "Sheet","Results", "FileType","spreadsheet");

%% ---- 8) Summary ----
rowOff = resOff(1,:);
rowOn  = resOn(1,:);

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

%% ---- 9) Optional: re-run best ALLOWED and plot ----
%% === (VIS) Show best result for MACD OFF / ON ===
% 붙여넣기 위치: 최적화 루프/저장까지 끝난 뒤(스크립트 맨 아래)

% -------- 0) 결과 테이블 로드 (workspace 우선, 없으면 xlsx 탐색) --------
T_off = [];
T_on  = [];

% (1) workspace 변수로 존재하면 우선 사용
candOff = {'resultsOff','T_off','resOff','tblOff'};
candOn  = {'resultsOn','T_on','resOn','tblOn'};

for i=1:numel(candOff)
    if evalin('base', sprintf("exist('%s','var')", candOff{i}))
        T_off = evalin('base', candOff{i});
        break;
    end
end
for i=1:numel(candOn)
    if evalin('base', sprintf("exist('%s','var')", candOn{i}))
        T_on = evalin('base', candOn{i});
        break;
    end
end

% (2) 없으면 xlsx 파일에서 읽기
if isempty(T_off)
    f = dir("opt_results*OFF*.xlsx");
    if isempty(f), f = dir("opt_results*MACD*OFF*.xlsx"); end
    if ~isempty(f)
        [~, newest] = max([f.datenum]);
        T_off = readtable(fullfile(f(newest).folder, f(newest).name));
        fprintf("[VIS] Loaded OFF results from %s\n", f(newest).name);
    end
end

if isempty(T_on)
    f = dir("opt_results*ALLOWED*.xlsx");
    if isempty(f), f = dir("opt_results*MACD*ALLOWED*.xlsx"); end
    if ~isempty(f)
        [~, newest] = max([f.datenum]);
        T_on = readtable(fullfile(f(newest).folder, f(newest).name));
        fprintf("[VIS] Loaded ON results from %s\n", f(newest).name);
    end
end

if isempty(T_off) || isempty(T_on)
    error("최적화 결과 테이블을 찾지 못했습니다. (workspace 변수 또는 opt_results*.xlsx 파일 확인)");
end

% -------- 1) Best row 선택 --------
mustHave = "Score";
if ~any(strcmpi(T_off.Properties.VariableNames, mustHave)) || ~any(strcmpi(T_on.Properties.VariableNames, mustHave))
    error("결과 테이블에 'Score' 컬럼이 없습니다. 결과 저장 포맷을 확인해주세요.");
end

[~, iBestOff] = max(T_off.Score);
[~, iBestOn]  = max(T_on.Score);

bestOff = T_off(iBestOff,:);
bestOn  = T_on(iBestOn,:);

fprintf("\n=== BEST OFF ===\n"); disp(bestOff);
fprintf("\n=== BEST ON  ===\n"); disp(bestOn);

% -------- 2) 파라미터 디코딩 (ParamsJson 우선, 없으면 row->struct) --------
pOff = decode_params_row(bestOff);
pOn  = decode_params_row(bestOn);

% -------- 3) 공통 설정(심볼/기간/데이터) : 기존 스크립트 변수 재사용 시도 --------
% 최적화 스크립트에서 이미 정의되어 있을 가능성이 큼: panel, sd, ed, symbol, initialCapital
if exist('panelFile','var') ~= 1
    panelFile = "kospi_top100_ohlc_30y.csv"; % <- 필요하면 여기 직접 지정
end
if exist('sd','var') ~= 1, sd = datetime(2020,1,1); end
if exist('ed','var') ~= 1, ed = datetime(2024,12,31); end
if exist('symbol','var') ~= 1, symbol = "005930"; end
if exist('initialCapital','var') ~= 1, initialCapital = 1e9; end

% -------- 4) OFF best 재실행 + plot --------
fprintf("\n[VIS] Re-run BEST OFF...\n");
[engOff, pmOff] = run_one_best(panelFile, symbol, sd, ed, initialCapital, pOff, "OFF");
engOff.plot();

% -------- 5) ON best 재실행 + plot --------
fprintf("\n[VIS] Re-run BEST ON...\n");
[engOn, pmOn] = run_one_best(panelFile, symbol, sd, ed, initialCapital, pOn, "ON");
engOn.plot();

% -------- 6) 간단 비교 플롯(EquityCurve) --------
try
    figure('Name','Equity comparison (OFF vs ON)');
    t1 = pmOff.Portfolio.EquityCurve.Properties.RowTimes;
    e1 = pmOff.Portfolio.EquityCurve.Equity;
    t2 = pmOn.Portfolio.EquityCurve.Properties.RowTimes;
    e2 = pmOn.Portfolio.EquityCurve.Equity;
    plot(t1, e1); hold on; plot(t2, e2);
    legend("MACD OFF (best)","MACD ON (best)","Location","best");
    grid on; title("EquityCurve comparison");
catch ME
    warning("비교 플롯 실패: %s", ME.message);
end

%% ======== helper functions (script-local) ========

function p = decode_params_row(row)
    % ParamsJson 컬럼이 있으면 jsondecode, 없으면 row 전체를 struct로
    vn = row.Properties.VariableNames;
    idx = find(strcmpi(vn, 'ParamsJson'), 1);
    if ~isempty(idx)
        pj = row{1, idx};
        if iscell(pj), pj = pj{1}; end
        if isstring(pj), pj = char(pj); end
        p = jsondecode(pj);
    else
        p = table2struct(row);
    end
end

function [eng, pm] = run_one_best(panel, symbol, sd, ed, initialCapital, params, macdMode)
    % 1) portfolio master + DM
    pm = portfolio_master(initialCapital);

    dm = ticker_data_manager(panel, symbol, sd, ed);

    % 2) Spec: 고객님 요청 반영(노출 1.0, fee/tax 반영, borrow 0.04, 평가 close는 엔진에서)
    spec = instrument_spec(symbol, string(symbol), ...
        "MaxNotionalFrac", 1.0, ...
        "BorrowRateAnnual", 0.04);

    % fee/tax 모델이 존재하면 유지(스크립트에 이미 있으면 그걸 우선 사용)
    if exist("fee_model_rate","class") == 8
        spec.FeeModel = fee_model_rate(0.00015, 0.00010);
    end
    if exist("tax_model_krx_stt","class") == 8
        spec.TaxModel = tax_model_krx_stt(0.0018, 0.0015);
    end

    % 3) Trader 생성 + 파라미터 적용
    tr = ticker_trader(dm, 0, true);

    % (중요) 옵션 A: trader는 intent만 내고 fill로 동기화되도록 외부회계 모드
    if ismethod(tr, "enable_external_accounting")
        tr.enable_external_accounting(true);
    end

    % MACD 모드 반영: (필드명이 프로젝트마다 다를 수 있어 안전하게 여러 후보를 시도)
    tr = set_if_has(tr, "ForceMACDOff", strcmpi(macdMode,"OFF"));
    tr = set_if_has(tr, "UseMACDFilter", strcmpi(macdMode,"ON"));
    tr = set_if_has(tr, "EnableMACD", strcmpi(macdMode,"ON"));

    % params struct을 trader에 적용(존재하는 필드만)
    tr = apply_params_safe(tr, params);

    % 4) Universe 등록 + 엔진
    pm.add_instrument(dm, spec, tr);

    eng = portfolio_backtest_engine(pm);
    eng.StartDate = sd;
    eng.EndDate   = ed;

    % 체결=open, 평가=close 유지(엔진 속성이 있으면 명시)
    if isprop(eng,"ValuationMode"), eng.ValuationMode = "CLOSE"; end

    eng.run();

    % 요약 출력
    eq = pm.Portfolio.EquityCurve.Equity;
    endEq = eq(end);
    maxDD = calc_maxdd(eq);
    nTrPf = height(pm.Portfolio.TradeLog);
    fprintf("[VIS-%s] endEq=%.0f MaxDD=%.4f TradesPf=%d\n", macdMode, endEq, maxDD, nTrPf);
end

function tr = apply_params_safe(tr, params)
    % params가 struct(또는 jsondecode 결과 struct)라고 가정하고,
    % trader에 같은 이름의 property가 있으면 set.
    if ~isstruct(params), return; end
    f = fieldnames(params);
    for i=1:numel(f)
        key = f{i};
        val = params.(key);
        % 숫자/논리/string/char 정도만 안전하게 적용
        try
            if isprop(tr, key)
                tr.(key) = val;
            end
        catch
            % 무시: 타입이 안 맞거나 SetAccess 제한 등
        end
    end
end

function obj = set_if_has(obj, propName, value)
    try
        if isprop(obj, propName)
            obj.(propName) = value;
        end
    catch
    end
end

function mdd = calc_maxdd(eq)
    eq = double(eq(:));
    peak = -inf;
    mdd = 0;
    for i=1:numel(eq)
        if eq(i) > peak, peak = eq(i); end
        dd = (peak - eq(i)) / max(peak, eps);
        if dd > mdd, mdd = dd; end
    end
end


%% ======================= LOCAL FUNCTIONS =======================

function spec = build_default_krx_equity_spec(symbol)
% build_default_krx_equity_spec
% - 본인의 환경에서 instrument_spec/fee_model/tax_model/margin_model 클래스명이
%   다르면 여기만 맞춰주시면 됩니다.

    symbol = string(symbol);

    if exist('instrument_spec','class') == 8
        % Fee/Tax/Margin 모델은 사용자 프로젝트에 이미 존재한다고 가정
        fee = [];
        if exist('fee_model_rate','class') == 8
            fee = fee_model_rate(0.00015, 0.00010); % (commission, slippage)
        end
        tax = [];
        if exist('tax_model_krx_stt','class') == 8
            tax = tax_model_krx_stt(0.0018, 0.0015); % (stock, etf) - 필요시 수정
        end
        mar = [];
        if exist('margin_model_simple','class') == 8
            mar = margin_model_simple(0.0, 0.50, 0.30); % long, short init, short maint
        end

        spec = instrument_spec(symbol, "KRX_Equity", ...
            "FeeModel", fee, ...
            "TaxModel", tax, ...
            "MarginModel", mar, ...
            "BorrowRateAnnual", 0.02, ...
            "MaxNotionalFrac", 1.00, ...
            "AllowShort", true, ...
            "Multiplier", 1.0);
    else
        error("instrument_spec class not found. 신규 아키텍처 파일들이 MATLAB path에 있는지 확인하세요.");
    end
end

function [bestParams, bestScore, results] = optimize_random(panelFile, ticker, initialCapital, S, spec, startDate, endDate, ...
    maxEvals, ddPenalty, useLogEquity, verbose)

    bestScore = -Inf;
    bestParams = struct();

    % 미리 결과 테이블 스키마 생성
    results = table('Size',[0 9], ...
        'VariableTypes',["double","double","double","double","double","double","double","double","string"], ...
        'VariableNames',["Eval","Score","EquityEnd","TotRet","CAGR","MaxDD","Trades","Stops","ParamsJson"]);

    for k = 1:maxEvals
        params = sample_params(S);

        % EnableShort는 spec.AllowShort에도 반영 (자산별 short 허용과 전략의 short 허용을 분리)
        if isfield(params, 'EnableShort')
            spec.AllowShort = logical(params.EnableShort);
        end

        [rep, ~] = run_one_portfolio(panelFile, ticker, initialCapital, params, spec, startDate, endDate, ddPenalty, useLogEquity);

        if rep.Score > bestScore
            bestScore = rep.Score;
            bestParams = params;
            if verbose
                fprintf("[Best] eval=%d score=%.6f endEq=%.0f MaxDD=%.4f Trades=%d\n", ...
                    k, rep.Score, rep.EquityEnd, rep.MaxDD, rep.Trades);
            end
        elseif verbose && mod(k, max(1, floor(maxEvals/20))) == 0
            fprintf("eval=%d score=%.6f endEq=%.0f MaxDD=%.4f Trades=%d\n", ...
                k, rep.Score, rep.EquityEnd, rep.MaxDD, rep.Trades);
        end

        pj = string(jsonencode(params));
        results = [results; {k, rep.Score, rep.EquityEnd, rep.TotRet, rep.CAGR, rep.MaxDD, rep.Trades, rep.Stops, pj}]; %#ok<AGROW>
    end
end

function params = sample_params(S)
% 각 필드에서 랜덤으로 1개 값을 샘플링
    params = struct();
    fns = fieldnames(S);
    for i=1:numel(fns)
        fn = fns{i};
        vals = S.(fn);

        if ischar(vals) || isstring(vals)
            vals = string(vals);
            idx = randi(numel(vals));
            params.(fn) = vals(idx);
        elseif islogical(vals)
            idx = randi(numel(vals));
            params.(fn) = logical(vals(idx));
        elseif isnumeric(vals)
            idx = randi(numel(vals));
            params.(fn) = vals(idx);
        else
            % cell 등은 그대로 샘플
            if iscell(vals)
                idx = randi(numel(vals));
                params.(fn) = vals{idx};
            else
                params.(fn) = vals;
            end
        end
    end
end

function [rep, eqTT] = run_one_portfolio(panelFile, ticker, initialCapital, params, spec, startDate, endDate, ddPenalty, useLogEquity)

    assert(exist('portfolio_master','class') == 8, "portfolio_master class not found in MATLAB path");
    assert(exist('portfolio_backtest_engine','class') == 8, "portfolio_backtest_engine class not found in MATLAB path");

    % --- Build DM (trimmed) ---
    dm = ticker_data_manager(panelFile, ticker, startDate, endDate);

    % --- Build trader ---
    tr = ticker_trader(dm, 0, true);
    if ismethod(tr, 'enable_external_accounting')
        tr.enable_external_accounting(true);
    end
    if ismethod(tr, 'set_hparams')
        tr.set_hparams(params);
    else
        apply_params_compat(tr, params);
    end

    % --- Portfolio ---
    pm = portfolio_master(initialCapital);
    pm.add_instrument(dm, spec, tr);

    eng = portfolio_backtest_engine(pm);
    if isprop(eng, 'StartDate'), eng.StartDate = startDate; end
    if isprop(eng, 'EndDate'),   eng.EndDate   = endDate;   end

    eng.run();

    % equity curve source
    if isprop(pm, 'Portfolio') && isprop(pm.Portfolio, 'EquityCurve')
        eqTT = pm.Portfolio.EquityCurve;
    elseif isprop(eng, 'EquityCurve')
        eqTT = eng.EquityCurve;
    else
        error('Cannot locate EquityCurve (pm.Portfolio.EquityCurve or eng.EquityCurve)');
    end

    eq = eqTT.Equity;
    dt = eqTT.Properties.RowTimes;

    rep = struct();
    rep.EquityEnd = eq(end);
    rep.TotRet = eq(end)/eq(1) - 1;
    rep.CAGR = compute_cagr(dt, eq);
    rep.MaxDD = compute_maxdd(eq);

    % Trades/Stops: trader 로그를 우선 사용 (전략 레벨에서 동일하게 유지되는 게 목표)
    rep.Trades = 0; rep.Stops = 0;
    if isprop(tr, 'TradeLog')
        rep.Trades = height(tr.TradeLog);
    elseif isprop(pm.Portfolio, 'TradeLog')
        rep.Trades = height(pm.Portfolio.TradeLog);
    end
    if isprop(tr, 'StopLog')
        rep.Stops  = height(tr.StopLog);
    end

    if useLogEquity
        rep.Score = log(max(rep.EquityEnd, 1)) - ddPenalty * rep.MaxDD;
    else
        rep.Score = rep.TotRet - ddPenalty * rep.MaxDD;
    end
end

function apply_params_compat(tr, params)
% set_hparams가 없는 구버전 호환
    fns = fieldnames(params);
    for k = 1:numel(fns)
        fn = fns{k};
        if isprop(tr, fn)
            try
                tr.(fn) = params.(fn);
            catch
                % ignore type mismatch
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
