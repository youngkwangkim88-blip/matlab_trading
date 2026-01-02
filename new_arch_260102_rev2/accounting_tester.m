classdef accounting_tester < handle
    % accounting_tester
    %
    % 목적:
    %  - 단일/다중 종목 백테스트 1회 실행 결과에 대해,
    %    (1) trader 로그 (ticker_trader.TradeLog)
    %    (2) engine/portfolio 로그 (portfolio_account.TradeLog, EquityCurve, engine.RejectionLog)
    %    를 교차 검증하여 "거래는 했다" vs "회계 반영이 됐다"를 빠르게 점검합니다.
    %
    % 전제(현재 아키텍처):
    %  - trader는 Pos(-1/0/+1) 시그널을 생성하고 TradeLog에 ENTER/EXIT를 기록
    %  - portfolio_backtest_engine이 sizing/fee/tax/margin 제약을 반영하여 실제 체결 수량을 결정
    %  - 실제 체결은 portfolio_account.TradeLog에 기록

    properties
        Master portfolio_master
        Engine portfolio_backtest_engine

        FailFast logical = false
        Verbose logical = true

        % equity 재계산 샘플링 개수 (너무 크게 하면 느려집니다)
        EquityCheckSamples double = 10

        % 허용 오차 (상대/절대)
        EquityRelTol double = 1e-8
        EquityAbsTol double = 1e-6
    end

    methods
        function this = accounting_tester(master, engine)
            if nargin < 1 || isempty(master) || ~isa(master,'portfolio_master')
                error('accounting_tester:BadMaster','master must be a portfolio_master');
            end
            if nargin < 2 || isempty(engine) || ~isa(engine,'portfolio_backtest_engine')
                error('accounting_tester:BadEngine','engine must be a portfolio_backtest_engine');
            end
            this.Master = master;
            this.Engine = engine;
        end

        function print_report(this, R)
            % print_report(R)
            if nargin < 2 || isempty(R)
                return;
            end

            if R.Pass
                fprintf('[ACCOUNTING TEST] PASS\n');
            else
                fprintf('[ACCOUNTING TEST] FAIL\n');
            end

            % Per-symbol summary
            if ~isempty(R.PerSymbol)
                fprintf('--- Per Symbol ---\n');
                for i = 1:numel(R.PerSymbol)
                    s = R.PerSymbol(i);
                    fprintf('%s | TraderTrades=%d PortfolioTrades=%d Rejected=%d MissingPf=%d MissingTr=%d FinalPosMatch=%d\n', ...
                        char(s.Symbol), s.TraderTrades, s.PortfolioTrades, s.Rejected, s.MissingInPortfolio, s.MissingInTrader, s.FinalPosMatch);
                end
            end

            % Issues (show top 30)
            if ~isempty(R.Issues) && istable(R.Issues) && height(R.Issues) > 0
                fprintf('--- Issues (Top 30) ---\n');
                T = R.Issues;
                nshow = min(30, height(T));
                disp(T(1:nshow,:));
            end
        end

        function R = verify(this)
            % verify()
            %  - 백테스트 실행 후 호출하세요. (eng.run() 이후)
            %  - 결과 R:
            %      R.Pass
            %      R.Issues (table)
            %      R.PerSymbol (struct array)

            L = this.Engine.get_logs();
            TLp = L.PortfolioTradeLog;
            EC  = L.EquityCurve;
            RJ  = L.RejectionLog;

            issues = this.empty_issue_table();

            inst = this.Master.Instruments;
            n = numel(inst);
            perSym = repmat(struct('Symbol',"",'TraderTrades',0,'PortfolioTrades',0,'Rejected',0,'MissingInPortfolio',0,'MissingInTrader',0,'FinalPosMatch',true), n, 1);

            for i = 1:n
                sym = string(inst(i).Spec.Symbol);
                if strlength(sym)==0
                    sym = string(inst(i).DM.Ticker);
                end
                tr = inst(i).Trader;

                % --- Trader TradeLog ---
                TLt = table();
                if ismethod(tr,'get_trade_log')
                    TLt = tr.get_trade_log();
                elseif isprop(tr,'TradeLog')
                    TLt = tr.TradeLog;
                end
                if ~isempty(TLt)
                    isTradeAct = ismember(string(TLt.Action), ["ENTER","EXIT","FLIP","REBALANCE","TRADE"]);
                    TLt2 = TLt(isTradeAct,:);
                else
                    TLt2 = TLt;
                end

                % --- Portfolio TradeLog ---
                TLps = table();
                if ~isempty(TLp) && any(strcmpi(TLp.Properties.VariableNames,'Symbol'))
                    TLps = TLp(strcmpi(string(TLp.Symbol), sym), :);
                end

                % --- RejectionLog ---
                RJs = table();
                if ~isempty(RJ) && any(strcmpi(RJ.Properties.VariableNames,'Symbol'))
                    RJs = RJ(strcmpi(string(RJ.Symbol), sym), :);
                end

                perSym(i).Symbol = sym;
                perSym(i).TraderTrades = height(TLt2);
                perSym(i).PortfolioTrades = height(TLps);
                perSym(i).Rejected = height(RJs);

                % 1) trader action date -> portfolio trade date 매칭
                missP = 0;
                if ~isempty(TLt2)
                    dtT = unique(TLt2.Time);
                    for k=1:numel(dtT)
                        dt = dtT(k);
                        hasP = false;
                        if ~isempty(TLps)
                            hasP = any(TLps.Time == dt);
                        end
                        if ~hasP
                            % rejection이면 정상(거래 의도는 있었으나 거부)
                            if ~isempty(RJs) && any(RJs.Time == dt)
                                issues = this.add_issue(issues, "WARN", sym, dt, "TraderActionWithoutPortfolioTrade", "engine rejected (see RejectionLog)");
                            else
                                missP = missP + 1;
                                issues = this.add_issue(issues, "ERR", sym, dt, "TraderActionWithoutPortfolioTrade", "no corresponding portfolio trade");
                                if this.FailFast
                                    R = this.finalize_report(false, issues, perSym, EC, L);
                                    return;
                                end
                            end
                        end
                    end
                end
                perSym(i).MissingInPortfolio = missP;

                % 2) portfolio trade date -> trader action date 매칭
                missT = 0;
                if ~isempty(TLps)
                    dtP = unique(TLps.Time);
                    for k=1:numel(dtP)
                        dt = dtP(k);
                        hasT = false;
                        if ~isempty(TLt2)
                            hasT = any(TLt2.Time == dt);
                        end
                        if ~hasT
                            missT = missT + 1;
                            issues = this.add_issue(issues, "WARN", sym, dt, "PortfolioTradeWithoutTraderAction", "portfolio executed but trader log has no fill action that day");
                        end
                    end
                end
                perSym(i).MissingInTrader = missT;

                % 3) final position sign match
                try
                    p = this.Master.Portfolio.get_position(sym);
                    posP = sign(double(p.Qty));
                    posT = 0;
                    if isprop(tr,'Pos')
                        posT = sign(double(tr.Pos));
                    end
                    if posP ~= posT
                        perSym(i).FinalPosMatch = false;
                        issues = this.add_issue(issues, "ERR", sym, NaT, "FinalPosMismatch", sprintf('portfolio=%d trader=%d',posP,posT));
                    end
                catch
                    % ignore
                end

            end

            % 4) EquityCurve integrity + spot-check compute_equity
            [issues, okEq] = this.check_equity_curve(issues, EC);
            [issues, okCost] = this.check_costs(issues, L);

            pass = okEq && okCost && ~any(strcmpi(string(issues.Level),"ERR"));
            R = this.finalize_report(pass, issues, perSym, EC, L);

            if this.Verbose
                this.print_summary(R);
            end
        end

        function print_summary(this, R)
            fprintf('\n=== Accounting Tester Summary ===\n');
            fprintf('Pass: %d\n', logical(R.Pass));
            fprintf('Issues: %d (ERR=%d, WARN=%d)\n', height(R.Issues), sum(strcmpi(R.Issues.Level,'ERR')), sum(strcmpi(R.Issues.Level,'WARN')));

            if ~isempty(R.PerSymbol)
                for i=1:numel(R.PerSymbol)
                    s = R.PerSymbol(i);
                    fprintf(' - %s: TraderTrades=%d, PortfolioTrades=%d, Rejected=%d, MissingP=%d, MissingT=%d, FinalPosMatch=%d\n', ...
                        s.Symbol, s.TraderTrades, s.PortfolioTrades, s.Rejected, s.MissingInPortfolio, s.MissingInTrader, s.FinalPosMatch);
                end
            end

            if height(R.Issues) > 0
                disp(R.Issues);
            end
        end
    end

    methods (Access=private)
        function T = empty_issue_table(this) %#ok<MANU>
            T = table('Size',[0 5], ...
                'VariableTypes',["string","string","datetime","string","string"], ...
                'VariableNames',["Level","Symbol","Time","Code","Detail"]);
        end

        function T = add_issue(this, T, level, sym, dt, code, detail) %#ok<INUSL>
            if nargin < 5 || isempty(dt), dt = NaT; end
            T = [T; {string(level), string(sym), dt, string(code), string(detail)}]; %#ok<AGROW>
        end

        function [T, ok] = check_equity_curve(this, T, EC)
            ok = true;
            if isempty(EC) || height(EC) == 0
                T = this.add_issue(T, "ERR", "(PORTFOLIO)", NaT, "EquityCurveEmpty", "EquityCurve is empty");
                ok = false;
                return;
            end

            % monotonic time (row times)
            try
                dts = EC.Properties.RowTimes;
            catch
                % fallback: attempt common row-time names
                if ismember("Time", EC.Properties.VariableNames)
                    dts = EC.Time;
                elseif ismember("dt", EC.Properties.VariableNames)
                    dts = EC.dt;
                else
                    dts = datetime.empty(0,1);
                end
            end
            if numel(dts) >= 2 && any(diff(dts) <= seconds(0))
                T = this.add_issue(T, "ERR", "(PORTFOLIO)", NaT, "EquityCurveNonMonotonic", ...
                    "EquityCurve timestamps are not strictly increasing");
                ok = false;
            end

            % NaN / Inf
            if any(~isfinite(EC.Equity))
                T = this.add_issue(T, "ERR", "(PORTFOLIO)", NaT, "EquityCurveBadValues", "Equity contains NaN/Inf");
                ok = false;
            end

            
% spot check equity reconstruction from logs vs curve
% (Do NOT call Portfolio.compute_equity at historical dt directly because
%  Portfolio state is the *final* state after the run.)
try
    inst = this.Master.Instruments;
    n = numel(inst);
    if n > 0
        m = height(EC);
        ns = max(2, min(m, round(this.EquityCheckSamples)));
        idx = unique(round(linspace(1, m, ns)));

        % Use row times as dt anchor
        dtsAll = EC.Properties.RowTimes;

        for ii = 1:numel(idx)
            k = idx(ii);
            dt = dtsAll(k);

            % Build close-price map at dt (valuation uses close for EquityCurve)
            pxMap = containers.Map('KeyType','char','ValueType','double');
            for j=1:n
                sym = char(string(inst(j).Spec.Symbol));
                if isempty(sym)
                    sym = char(string(inst(j).DM.Ticker));
                end
                t = find(inst(j).DM.Date == dt, 1, 'first');
                if isempty(t)
                    continue;
                end
                % EquityCurve uses close valuation by design
                px = double(inst(j).DM.Close(t));
                if isfinite(px) && px > 0
                    pxMap(sym) = px;
                end
            end

            eqC = double(EC.Equity(k));
            eqR = double(this.reconstruct_equity_from_logs(dt, pxMap));

            err = abs(eqC - eqR);
            tol = max(this.EquityAbsTol, this.EquityRelTol * max(1.0, abs(eqC)));
            if err > tol
                ok = false;
                T = this.add_issue(T, "WARN", "(PORTFOLIO)", dt, "EquityMismatch", sprintf('curve=%.6g recompute=%.6g err=%.6g tol=%.6g', eqC, eqR, err, tol));
            end
        end
    end
catch ME
    ok = false;
    T = this.add_issue(T, "WARN", "(PORTFOLIO)", NaT, "EquityCheckFailed", string(ME.message));
end
end

function eq = reconstruct_equity_from_logs(this, dt, pxMap)
    % Reconstruct equity at date dt from executed portfolio logs.
    %
    % Uses:
    %  - Portfolio.TradeLog (executed trades, includes Fee/Tax)
    %  - Portfolio.BorrowLog (daily borrow costs)
    %  - InitialCapital as starting cash
    %  - Marks positions to close prices provided in pxMap
    %
    % Intended for tester validation only.

    P = this.Master.Portfolio;

    % Ensure logs are flushed from buffers
    TL = P.TradeLog;
    BL = P.BorrowLog;

    cash = double(P.InitialCapital);

    % Replay trades up to dt (inclusive)
    qtyMap = containers.Map('KeyType','char','ValueType','double');
    if ~isempty(TL) && height(TL) > 0
        sel = (TL.Time <= dt);
        T = TL(sel, :);

        for i=1:height(T)
            sym = char(T.Symbol(i));
            qd  = double(T.QtyDelta(i));
            px  = double(T.Price(i));

            mult = 1.0;
            if isa(this.Master.SpecMap,'containers.Map') && isKey(this.Master.SpecMap, sym)
                mult = double(this.Master.SpecMap(sym).Multiplier);
            end

            cash = cash - (qd * px * mult) - double(T.Fee(i)) - double(T.Tax(i));

            if isKey(qtyMap, sym)
                qtyMap(sym) = qtyMap(sym) + qd;
            else
                qtyMap(sym) = qd;
            end
        end
    end

    % Apply borrow costs up to dt (inclusive)
    if ~isempty(BL) && height(BL) > 0
        cash = cash - sum(double(BL.Cost(BL.Time <= dt)));
    end

    % Mark-to-market
    eq = cash;
    ks = qtyMap.keys;
    for i=1:numel(ks)
        sym = ks{i};
        q = double(qtyMap(sym));
        if q == 0
            continue;
        end

        px = NaN;
        if isa(pxMap,'containers.Map') && isKey(pxMap, sym)
            px = double(pxMap(sym));
        end
        if ~isfinite(px) || px <= 0
            try
                if isKey(P.LastPrices, sym)
                    px = double(P.LastPrices(sym));
                end
            catch
            end
        end
        if ~isfinite(px) || px <= 0
            continue;
        end

        mult = 1.0;
        if isa(this.Master.SpecMap,'containers.Map') && isKey(this.Master.SpecMap, sym)
            mult = double(this.Master.SpecMap(sym).Multiplier);
        end
        eq = eq + q * px * mult;
    end
end



        function [T, ok] = check_costs(this, T, L)
            % Check consistency of fee/tax/borrow accounting between logs and aggregates.
            %
            % Expectations:
            %  - sum(PortfolioTradeLog.Fee) == Portfolio.FeesPaid
            %  - sum(PortfolioTradeLog.Tax) == Portfolio.TaxesPaid
            %  - sum(Portfolio.BorrowLog.Cost) == Portfolio.BorrowPaid
            %  - Per-trader maps are best-effort (WARN if mismatch)

            ok = true;
            pf = this.Master.Portfolio;

            TLp = L.PortfolioTradeLog;

            % Fee / Tax totals
            if istable(TLp) && height(TLp) > 0
                if any(strcmpi(TLp.Properties.VariableNames,'Fee'))
                    sFee = sum(double(TLp.Fee));
                    if abs(sFee - double(pf.FeesPaid)) > max(this.EquityAbsTol, abs(double(pf.FeesPaid))*1e-9)
                        T = this.add_issue(T, "ERR", "(PORTFOLIO)", NaT, "FeeTotalMismatch", sprintf('sum(TLp.Fee)=%.6g vs pf.FeesPaid=%.6g', sFee, double(pf.FeesPaid)));
                        ok = false;
                    end
                end
                if any(strcmpi(TLp.Properties.VariableNames,'Tax'))
                    sTax = sum(double(TLp.Tax));
                    if abs(sTax - double(pf.TaxesPaid)) > max(this.EquityAbsTol, abs(double(pf.TaxesPaid))*1e-9)
                        T = this.add_issue(T, "ERR", "(PORTFOLIO)", NaT, "TaxTotalMismatch", sprintf('sum(TLp.Tax)=%.6g vs pf.TaxesPaid=%.6g', sTax, double(pf.TaxesPaid)));
                        ok = false;
                    end
                end

                % Per-trader fee/tax aggregates (best-effort)
                if any(strcmpi(TLp.Properties.VariableNames,'TraderId'))
                    trIds = unique(string(TLp.TraderId));
                    for ii = 1:numel(trIds)
                        tid = trIds(ii);
                        if strlength(tid) == 0
                            continue;
                        end
                        m = (string(TLp.TraderId) == tid);
                        sFeeTid = 0; sTaxTid = 0;
                        if any(strcmpi(TLp.Properties.VariableNames,'Fee'))
                            sFeeTid = sum(double(TLp.Fee(m)));
                        end
                        if any(strcmpi(TLp.Properties.VariableNames,'Tax'))
                            sTaxTid = sum(double(TLp.Tax(m)));
                        end

                        try
                            if isa(pf.FeesByTrader,'containers.Map') && isKey(pf.FeesByTrader, char(tid))
                                v = double(pf.FeesByTrader(char(tid)));
                                if abs(v - sFeeTid) > max(this.EquityAbsTol, abs(v)*1e-9)
                                    T = this.add_issue(T, "WARN", "(PORTFOLIO)", NaT, "FeeByTraderMismatch", sprintf('TraderId=%s map=%.6g vs sum=%.6g', tid, v, sFeeTid));
                                end
                            end
                            if isa(pf.TaxesByTrader,'containers.Map') && isKey(pf.TaxesByTrader, char(tid))
                                v = double(pf.TaxesByTrader(char(tid)));
                                if abs(v - sTaxTid) > max(this.EquityAbsTol, abs(v)*1e-9)
                                    T = this.add_issue(T, "WARN", "(PORTFOLIO)", NaT, "TaxByTraderMismatch", sprintf('TraderId=%s map=%.6g vs sum=%.6g', tid, v, sTaxTid));
                                end
                            end
                        catch
                            % ignore
                        end
                    end
                end
            end

            % Borrow totals
            try
                BL = pf.BorrowLog;
                if istable(BL) && height(BL) > 0 && any(strcmpi(BL.Properties.VariableNames,'Cost'))
                    sBor = sum(double(BL.Cost));
                    if abs(sBor - double(pf.BorrowPaid)) > max(this.EquityAbsTol, abs(double(pf.BorrowPaid))*1e-9)
                        T = this.add_issue(T, "ERR", "(PORTFOLIO)", NaT, "BorrowTotalMismatch", sprintf('sum(BL.Cost)=%.6g vs pf.BorrowPaid=%.6g', sBor, double(pf.BorrowPaid)));
                        ok = false;
                    end

                    if any(strcmpi(BL.Properties.VariableNames,'TraderId'))
                        trIds = unique(string(BL.TraderId));
                        for ii = 1:numel(trIds)
                            tid = trIds(ii);
                            if strlength(tid) == 0
                                continue;
                            end
                            m = (string(BL.TraderId) == tid);
                            sBorTid = sum(double(BL.Cost(m)));
                            try
                                if isa(pf.BorrowByTrader,'containers.Map') && isKey(pf.BorrowByTrader, char(tid))
                                    v = double(pf.BorrowByTrader(char(tid)));
                                    if abs(v - sBorTid) > max(this.EquityAbsTol, abs(v)*1e-9)
                                        T = this.add_issue(T, "WARN", "(PORTFOLIO)", NaT, "BorrowByTraderMismatch", sprintf('TraderId=%s map=%.6g vs sum=%.6g', tid, v, sBorTid));
                                    end
                                end
                            catch
                                % ignore
                            end
                        end
                    end
                end
            catch
                % ignore
            end
        end
        function R = finalize_report(this, pass, issues, perSym, EC, logs) %#ok<INUSL>
            R = struct();
            R.Pass = logical(pass);
            R.Issues = issues;
            R.PerSymbol = perSym;
            R.EquityCurve = EC;
            R.EngineLogs = logs;
        end
    end
end
