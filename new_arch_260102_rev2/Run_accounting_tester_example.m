%% Run_accounting_tester_example.m
% Purpose:
%   - Run a 2-instrument / 2-trader portfolio backtest
%   - Run accounting_tester verification (Trader log vs Portfolio log)
%   - Print portfolio totals using *canonical* portfolio_account properties
%     (Cash / FeesPaid / TaxesPaid / BorrowPaid) WITHOUT relying on report() aliases.
%
% Notes on API discipline:
%   - This script intentionally does NOT reference report fields like TotalFeesPaid.
%   - It also does NOT try to support multiple report schemas.
%   - If you need a richer report, standardize portfolio_account.report() outputs
%     and update this script once, rather than adding aliases here.

clear; clc;

%% === User settings (edit these) ===
panelCsvFile = "kospi_top100_ohlc_30y.csv";              % e.g. "KOSPI_top20_panel.csv"  (leave "" if your ticker_data_manager doesn't need it)
sd = datetime(2020,1,1);
ed = datetime(2024,12,31);
initialCapital = 1e9;

sym1 = "005930";   % Samsung Electronics
sym2 = "000660";   % SK hynix

%% === Build portfolio master ===
pm = portfolio_master(initialCapital);

dm1 = ticker_data_manager(panelCsvFile, sym1, sd, ed);
dm2 = ticker_data_manager(panelCsvFile, sym2, sd, ed);

% Instrument specs (set to your current agreed defaults)
spec1 = instrument_spec(sym1, "KRX_STOCK", "MaxNotionalFrac", 1.0, "BorrowRateAnnual", 0.04);
spec2 = instrument_spec(sym2, "KRX_STOCK", "MaxNotionalFrac", 1.0, "BorrowRateAnnual", 0.04);

% Fee/Tax models (optional, only if classes exist in your codebase)
if exist("fee_model_rate","class") == 8
    spec1.FeeModel = fee_model_rate(0.00015, 0.00010);
    spec2.FeeModel = fee_model_rate(0.00015, 0.00010);
end
if exist("tax_model_krx_stt","class") == 8
    spec1.TaxModel = tax_model_krx_stt(0.0018, 0.0015);
    spec2.TaxModel = tax_model_krx_stt(0.0018, 0.0015);
end
if exist("margin_model_simple","class") == 8
    spec1.MarginModel = margin_model_simple();
    spec2.MarginModel = margin_model_simple();
end
if exist("null_exec_model","class") == 8
    spec1.ExecModel = null_exec_model();
    spec2.ExecModel = null_exec_model();
end

% Traders
tr1 = ticker_trader(dm1, 0, true);
tr2 = ticker_trader(dm2, 0, true);

% Option-A mode: trader logs should reflect actual fills (engine callback)
if ismethod(tr1, "enable_external_accounting"); tr1.enable_external_accounting(true); end
if ismethod(tr2, "enable_external_accounting"); tr2.enable_external_accounting(true); end

pm.add_instrument(dm1, spec1, tr1);
pm.add_instrument(dm2, spec2, tr2);

%% === Run engine ===
eng = portfolio_backtest_engine(pm);
eng.StartDate = sd;
eng.EndDate   = ed;
if isprop(eng,"Verbose"); eng.Verbose = true; end

eng.run();

% Flush buffered logs if buffering is enabled in your codebase
try
    if ismethod(pm.Portfolio,"flush_all"); pm.Portfolio.flush_all(); end
catch
end
try
    if ismethod(tr1,"flush_buffers"); tr1.flush_buffers(); end
    if ismethod(tr2,"flush_buffers"); tr2.flush_buffers(); end
catch
end

%% === Accounting tester ===
tester = accounting_tester(pm, eng);
R = tester.verify();
tester.print_report(R);

%% === Portfolio totals (canonical properties, no report aliases) ===
P = pm.Portfolio;

% Equity (prefer EquityCurve end if available)
eq = NaN;
try
    if istimetable(P.EquityCurve) && height(P.EquityCurve) > 0 && any(strcmp("Equity", P.EquityCurve.Properties.VariableNames))
        eq = P.EquityCurve.Equity(end);
    end
catch
end
if isnan(eq)
    % Fall back to cash if equity curve missing (shouldn't happen in normal runs)
    eq = P.Cash;
end

fprintf("\n=== Portfolio Totals (canonical fields) ===\n");
fprintf("Equity=%.3f, Cash=%.3f, FeesPaid=%.3f, TaxesPaid=%.3f, BorrowPaid=%.3f\n", ...
    eq, P.Cash, P.FeesPaid, P.TaxesPaid, P.BorrowPaid);

%% === Open positions snapshot ===
try
    keysSym = P.Positions.keys;
catch
    keysSym = {};
end

if isempty(keysSym)
    fprintf("\nOpenPositions: (none)\n");
else
    symCol = strings(numel(keysSym),1);
    qtyCol = zeros(numel(keysSym),1);
    avgCol = nan(numel(keysSym),1);
    lastCol = nan(numel(keysSym),1);

    for i=1:numel(keysSym)
        k = keysSym{i};
        symCol(i) = string(k);
        pos = P.Positions(k);
        if isprop(pos,"Qty");      qtyCol(i) = double(pos.Qty); end
        if isprop(pos,"AvgPrice"); avgCol(i) = double(pos.AvgPrice); end

        % last price if portfolio tracks it
        try
            if isprop(P,"LastPrices") && isa(P.LastPrices,"containers.Map") && isKey(P.LastPrices,k)
                lastCol(i) = double(P.LastPrices(k));
            end
        catch
        end
    end

    Tpos = table(symCol, qtyCol, avgCol, lastCol, ...
        'VariableNames', {'Symbol','Qty','AvgPrice','LastPrice'});
    fprintf("\nOpenPositions:\n");
    disp(Tpos);
end

%% === Trader breakdown (requires TradeLog.TraderId) ===
fprintf("\n=== Trader Breakdown (from Portfolio.TradeLog) ===\n");
if ~istable(P.TradeLog)
    fprintf("Portfolio.TradeLog not available.\n");
else
    TL = P.TradeLog;
    if ~any(strcmp("TraderId", TL.Properties.VariableNames))
        fprintf("TradeLog has no TraderId column; cannot attribute trades/costs per trader.\n");
    else
        tids = unique(TL.TraderId);
        tids = tids(tids ~= "");
        for i=1:numel(tids)
            tid = tids(i);
            idx = (TL.TraderId == tid);
            fees_i = 0; taxes_i = 0;
            if any(strcmp("Fee", TL.Properties.VariableNames)); fees_i = sum(double(TL.Fee(idx))); end
            if any(strcmp("Tax", TL.Properties.VariableNames)); taxes_i = sum(double(TL.Tax(idx))); end

            fprintf("TraderId=%s: Trades=%d, Fees=%.3f, Taxes=%.3f\n", ...
                tid, sum(idx), fees_i, taxes_i);
        end
    end
end
