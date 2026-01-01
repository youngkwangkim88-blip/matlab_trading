classdef backtest_engine < handle
    % backtest_engine
    % - Hyperparameters: slippage, commission, tax, borrow fee
    % - Time marching simulation
    % - Visualization
    % - Report generation (table + excel)

    properties
        Commission double = 0.00015
        Slippage double   = 0.00010
        STT_2024 double   = 0.0018
        STT_2025 double   = 0.0015
        ShortBorrowAnnual double = 0.0215
        TradingDays double = 252
        StartDate datetime = datetime(1900,1,1)
        EndDate   datetime = datetime(2100,12,31)
        Master trader_master
    end

    methods
        function [bestParams, bestScore, results] = optimize_trader_params(this, traderIndex, S, varargin)
        %OPTIMIZE_TRADER_PARAMS  Simple hyper-parameter search (grid/random) for one trader.
        %   [bestParams, bestScore, results] = eng.optimize_trader_params(traderIndex, S, ...)
        %
        % Inputs
        %   traderIndex : index into this.Master.Traders
        %   S           : struct array describing search space
        %                 S(k).Name   = 'ParamName'
        %                 S(k).Values = [ ... ] or { ... } or string array
        %
        % Name-Value (optional)
        %   'MaxEvals'    : maximum evaluations (default 300)
        %   'DDPenalty'   : score penalty weight for MaxDD (default 0.5)
        %   'Verbose'     : true/false (default true)
        %   'StartDate'   : override this.StartDate (optional)
        %   'EndDate'     : override this.EndDate   (optional)
        %   'Seed'        : rng seed (default 1)
        % --- Normalize S to struct array with fields Name/Values ---
            % --- Normalize S to struct array with fields Name/Values ---
            if isstruct(S) && isscalar(S) && ~(isfield(S,'Name') && isfield(S,'Values'))
                % Allow scalar struct with param fields: S.Param = [values]
                f = fieldnames(S);
                S2 = struct([]);
                for k = 1:numel(f)
                    S2(k).Name   = f{k};
                    S2(k).Values = S.(f{k});
                end
                S = S2;
            end


            % ---- Parse options (NO arguments block) ----
            ip = inputParser;
            ip.KeepUnmatched = true;
            addParameter(ip, 'MaxEvals', 300);
            addParameter(ip, 'DDPenalty', 0.5);
            addParameter(ip, 'Verbose', true);
            addParameter(ip, 'StartDate', []);
            addParameter(ip, 'EndDate', []);
            addParameter(ip, 'Seed', 1);
            parse(ip, varargin{:});
            Opt = ip.Results;
        
            rng(Opt.Seed);
        
            % ---- Basic validation ----
            if traderIndex < 1 || traderIndex > numel(this.Master.Traders)
                error('optimize_trader_params:BadTraderIndex', 'Invalid traderIndex=%d', traderIndex);
            end
            tr = this.Master.Traders(traderIndex);
        
            if isempty(S)
                error('optimize_trader_params:EmptySpace', 'Search space S is empty.');
            end
            if ~isstruct(S) || ~all(isfield(S, {'Name','Values'}))
                error('optimize_trader_params:BadSpace', 'S must be struct array with fields Name and Values.');
            end
        
            % ---- Override window if provided ----
            startBak = [];
            endBak   = [];
            if ~isempty(Opt.StartDate)
                startBak = this.StartDate;
                this.StartDate = Opt.StartDate;
            end
            if ~isempty(Opt.EndDate)
                endBak = this.EndDate;
                this.EndDate = Opt.EndDate;
            end
        
            % ---- Build candidate list (grid up to MaxEvals; otherwise random sample) ----
            names = string({S.Name});
            vals  = cell(1, numel(S));
            nEach = zeros(1, numel(S));
            for k = 1:numel(S)
                v = S(k).Values;
                if isnumeric(v) || islogical(v)
                    v = num2cell(v(:)');
                elseif isstring(v)
                    v = cellstr(v(:))';
                elseif iscell(v)
                    v = v(:)'; % row
                else
                    error('optimize_trader_params:BadValues', 'S(%d).Values must be numeric/logical/cell/string.', k);
                end
                vals{k} = v;
                nEach(k) = numel(v);
                if nEach(k) == 0
                    error('optimize_trader_params:EmptyValues', 'S(%d).Values is empty.', k);
                end
            end
        
            totalComb = prod(nEach);
            maxEvals  = min(Opt.MaxEvals, totalComb);
        
            % Make index matrix of candidates: each row = one combination of indices
            if totalComb <= maxEvals
                % full grid
                idxGrid = cell(1, numel(nEach));
                for k = 1:numel(nEach)
                    idxGrid{k} = 1:nEach(k);
                end
                [idxGrid{:}] = ndgrid(idxGrid{:});
                C = zeros(totalComb, numel(nEach));
                for k = 1:numel(nEach)
                    C(:,k) = idxGrid{k}(:);
                end
            else
                % random sample without replacement (approx)
                C = zeros(maxEvals, numel(nEach));
                for i = 1:maxEvals
                    for k = 1:numel(nEach)
                        C(i,k) = randi(nEach(k));
                    end
                end
            end
        
            % ---- Evaluate ----
            bestScore  = -Inf;
            bestParams = struct();
        
            results = table('Size',[size(C,1) 6], ...
                'VariableTypes', ["double","double","double","double","double","string"], ...
                'VariableNames', ["Score","EquityEnd","TotRet","CAGR","MaxDD","ParamsJson"]);
        
            if Opt.Verbose
                fprintf('[OPT] evaluating %d candidates (out of %d combinations)\n', size(C,1), totalComb);
            end
        
            % store fixed initial equity for TotRet/CAGR (do NOT depend on eq0)
            fixedInitEq = tr.get_equity();
            initEq = fixedInitEq;
            for i = 1:size(C,1)
                P = struct();
                for k = 1:numel(names)
                    P.(names(k)) = vals{k}{C(i,k)};
                end
        
                % Apply params to trader
                if ismethod(tr, "set_hparams")
                    tr.set_hparams(P);
                else
                    fns = fieldnames(P);
                    for kk = 1:numel(fns)
                        fn = fns{kk};
                        if isprop(tr, fn)
                            tr.(fn) = P.(fn);
                        end
                    end
                end
        
                % Reset & run
                if ismethod(tr, "reset_for_run")
                    tr.reset_for_run();
                end
                this.run();  % assumes run() uses this.StartDate/EndDate
        
                % Metrics from valuation curve (close-based)
                % ---- EquityEnd는 ValCurve(종가 평가) 기준으로 읽는다 ----
                if isprop(tr,'ValCurve') && ~isempty(tr.ValCurve) && any(tr.ValCurve.Properties.VariableNames=="EquityClose")
                    eqSeries = tr.ValCurve.EquityClose;
                    eqEnd = eqSeries(end);
                    eq0   = eqSeries(1);
                else
                    % fallback (구버전 호환)
                    eqEnd = tr.get_equity();
                    eq0   = tr.get_equity();
                    eqSeries = eqEnd;
                end

                if isprop(tr, 'ValCurve') && ~isempty(tr.ValCurve)
                    eqSeries = tr.ValCurve.EquityClose;
                    % Max drawdown
                    peak = cummax(eqSeries);
                    dd = (eqSeries - peak) ./ peak;
                    maxDD = -min(dd);
                    % CAGR (annualized) from Start/End
                    dt0 = tr.ValCurve.Properties.RowTimes(1);
                    dt1 = tr.ValCurve.Properties.RowTimes(end);
                    yrs = days(dt1 - dt0) / 365.25;
                    if yrs > 0
                        cagr = (eqEnd / initEq)^(1/yrs) - 1;
                    else
                        cagr = NaN;
                    end
                else
                    maxDD = NaN;
                    cagr  = NaN;
                end
        
                totRet = (eqEnd / initEq) - 1;
        
                % Score: log equity - penalty * MaxDD
                score = log(max(eqEnd, 1)) - Opt.DDPenalty * maxDD;
        
                results.Score(i)     = score;
                results.EquityEnd(i) = eqEnd;
                results.TotRet(i)    = totRet;
                results.CAGR(i)      = cagr;
                results.MaxDD(i)     = maxDD;
                results.ParamsJson(i)= string(jsonencode(P));
        
                if score > bestScore
                    bestScore  = score;
                    bestParams = P;
                    if Opt.Verbose
                        fprintf('[OPT] new best i=%d score=%.6f eq=%.3e maxDD=%.3f\n', i, bestScore, eqEnd, maxDD);
                    end
                end
            end
        
            % ---- Restore window overrides ----
            if ~isempty(startBak); this.StartDate = startBak; end
            if ~isempty(endBak);   this.EndDate   = endBak;   end
        end


        function r = short_borrow_daily(this)
            % annual borrow rate / trading days
            r = 0.0;
            if isprop(this,'ShortBorrowAnnual') && ~isempty(this.ShortBorrowAnnual)
                r = this.ShortBorrowAnnual / 252;
            elseif isprop(this,'shortBorrowRateAnnual') && ~isempty(this.ShortBorrowAnnual)
                r = this.ShortBorrowAnnual / 252;
            end
        end


        function this = backtest_engine(master)
            arguments
                master (1,1) trader_master
            end
            this.Master = master;
        end

        function fee = entryFee(this, targetPos, dt)
            fee = this.Commission + this.Slippage;
            % STT on SELL only:
            % short entry is SELL => apply STT
            if targetPos == -1
                fee = fee + this.stt(dt);
            end
        end

        function r = stt_rate(this, dt)
            % Public access to the securities transaction tax rate.
            % (Used for transparent logging in ticker_trader)
            r = this.stt(dt);
        end

        function fee = exitFee(this, currentPos, dt)
            fee = this.Commission + this.Slippage;
            % long exit is SELL => apply STT
            if currentPos == 1
                fee = fee + this.stt(dt);
            end
        end

        function d = shortBorrowDaily(this)
            d = this.ShortBorrowAnnual / this.TradingDays;
        end
        function run(this)
            if isempty(this.Master.Traders)
                error("backtest_engine:NoTraders","Master에 트레이더가 없습니다.");
            end
            % Always reset traders for this run (safe)
            this.Master.allocate_initial_equal();

            % Allocate initial if not allocated (simple check)
            if abs(this.Master.total_equity() - this.Master.InitialCapital) > 1e-6
                this.Master.allocate_initial_equal();
            end
        
            reqStart = this.StartDate;
            reqEnd   = this.EndDate;
        
            if reqEnd < reqStart
                error("backtest_engine:BadWindow","EndDate가 StartDate보다 빠릅니다.");
            end
        
            % ---- Check each trader data availability for requested window ----
            active = true(1, numel(this.Master.Traders));
            for i = 1:numel(this.Master.Traders)
                dm = this.Master.Traders(i).DM;
                [d0, d1] = dm.data_range();
        
                % no overlap
                if reqEnd < d0 || reqStart > d1
                    warning("Ticker %s: 요청 기간(%s~%s)이 데이터 기간(%s~%s)과 겹치지 않습니다. 이 트레이더는 제외됩니다.", ...
                        char(dm.Ticker), datestr(reqStart), datestr(reqEnd), datestr(d0), datestr(d1));
                    active(i) = false;
                    continue;
                end
        
                % partial overlap -> warn
                if reqStart < d0 || reqEnd > d1
                    warning("Ticker %s: 요청 기간(%s~%s) 중 일부는 데이터가 없습니다. 가능한 구간(%s~%s)만 사용합니다.", ...
                        char(dm.Ticker), datestr(reqStart), datestr(reqEnd), datestr(d0), datestr(d1));
                end
            end
        
            if ~any(active)
                error("backtest_engine:NoActiveTraders", "요청 기간에 대해 시뮬레이션 가능한 트레이더가 없습니다.");
            end
        
            traders = this.Master.Traders(active);
        
            % ---- Build common date grid = intersection of active traders within window ----
            commonDates = traders(1).DM.Date;
            commonDates = commonDates(commonDates >= reqStart & commonDates <= reqEnd);
        
            for i = 2:numel(traders)
                dt = traders(i).DM.Date;
                dt = dt(dt >= reqStart & dt <= reqEnd);
                commonDates = intersect(commonDates, dt);
            end
            commonDates = sort(commonDates);
        
            if numel(commonDates) < 50
                warning("공통 날짜(intersection)가 짧습니다: %d일. 기간/티커 데이터를 확인하세요.", numel(commonDates));
            end
        
            % ---- Map date->index for each trader ----
            idxMap = cell(numel(traders),1);
            for i=1:numel(traders)
                dt = traders(i).DM.Date;
                [~, loc] = ismember(commonDates, dt);
                idxMap{i} = loc;
            end
        
            % ---- Time-marching ----
            for k=1:numel(commonDates)
                for i=1:numel(traders)
                    t = idxMap{i}(k);
                    if t<=0, continue; end
                    traders(i).step(t, this);
                end
            end

            % ---- End-of-period forced close (short positions) ----
            if ~isempty(commonDates)
                dtEnd = commonDates(end);
                for i=1:numel(traders)
                    tEnd = idxMap{i}(end);
                    if tEnd <= 0, continue; end
                    % Only if short is still open at the end date
                    if isprop(traders(i),'Pos') && traders(i).Pos == -1
                        closePx = traders(i).DM.Close(tEnd);
                        if ismethod(traders(i),'force_close_end_of_period')
                            traders(i).force_close_end_of_period(dtEnd, closePx, this, false);
                        else
                            % Fallback: just flip to flat using existing step/exit logic if available
                            try
                                traders(i).exit_position(dtEnd, closePx, this, "EOP_FORCE_CLOSE", NaN, closePx);
                                traders(i).append_curves(dtEnd);
                            catch
                            end
                        end
                    end
                end
            end


        
            % ---- Put active traders back (since we used a local variable) ----
            % Note: traders array is a copy of handles, so underlying objects updated.
        end

        function rep = report(this)
            % Simple summary table per ticker
            n = numel(this.Master.Traders);
            rep = table('Size',[n 7], ...
                'VariableTypes', ["string","string","double","double","double","double","double"], ...
                'VariableNames', ["Ticker","Name","EquityEnd","TotRet","CAGR","Trades","Stops"]);

            for i=1:n
                tr = this.Master.Traders(i);
                eq = tr.EqCurve.Equity;
                dt = tr.EqCurve.Properties.RowTimes;
                dt = datetime(dt); % (RowTimes가 datetime이면 그대로, duration이면 변환)

                if numel(eq) < 2
                    TotRet = NaN; CAGR = NaN;
                else
                    TotRet = eq(end)/eq(1) - 1;
                    nYears = max(days(dt(end)-dt(1))/365.25, eps);
                    CAGR = (eq(end)/eq(1))^(1/nYears) - 1;
                end

                rep.Ticker(i) = tr.DM.Ticker;
                rep.Name(i)   = tr.DM.Name;
                rep.EquityEnd(i) = this.get_trader_equity_end(tr);
                rep.TotRet(i) = TotRet;
                rep.CAGR(i)   = CAGR;
                rep.Trades(i) = height(tr.TradeLog);
                rep.Stops(i)  = height(tr.StopLog);
            end
        end

        function save_excel(this, xlsxFile)
            rep = this.report();
            writetable(rep, xlsxFile, "Sheet","Summary", "FileType","spreadsheet");

            % also save per ticker logs
            for i = 1:numel(this.Master.Traders)
                tr = this.Master.Traders(i);
            
                base = this.make_sheet_name(char(tr.DM.Ticker));   % ex) '005930'
                sheetTrades = this.make_sheet_name([base '_trades']);
                sheetStops  = this.make_sheet_name([base '_stops']);
                sheetEq     = this.make_sheet_name([base '_equity']);
                sheetPos    = this.make_sheet_name([base '_pos']);
            
                writetable(tr.TradeLog, xlsxFile, "Sheet", sheetTrades, "FileType","spreadsheet");
                writetable(tr.StopLog,  xlsxFile, "Sheet", sheetStops,  "FileType","spreadsheet");
            
                eqT = timetable2table(tr.EqCurve, "ConvertRowTimes", true);
                psT = timetable2table(tr.PosSeries, "ConvertRowTimes", true);
            
                writetable(eqT, xlsxFile, "Sheet", sheetEq,  "FileType","spreadsheet");
                writetable(psT, xlsxFile, "Sheet", sheetPos, "FileType","spreadsheet");
            end

        end
        function plot(this)
            for i=1:numel(this.Master.Traders)
                tr = this.Master.Traders(i);
                dm = tr.DM;
        
                % ===== window mask =====
                win0 = this.StartDate;
                win1 = this.EndDate;
        
                maskP = (dm.Date >= win0) & (dm.Date <= win1);
        
                % (안전) equity/pos는 RowTimes 기준
                tEq = tr.EqCurve.Properties.RowTimes;
                maskE = (tEq >= win0) & (tEq <= win1);
        
                tPos = tr.PosSeries.Properties.RowTimes;
                maskS = (tPos >= win0) & (tPos <= win1);
        
                % ===== Figure =====
                figure("Name", sprintf("%s %s", char(dm.Ticker), char(dm.Name)), "Color","w");
                tiledlayout(2,1,"TileSpacing","compact","Padding","compact");
        
                % ===== Tile 1: Price & MA + Trade markers =====
                nexttile(1); hold on; grid on;
        
                % Price & MAs (windowed)
                plot(dm.Date(maskP), dm.Close(maskP), "LineWidth", 1.2);
                plot(dm.Date(maskP), dm.smaWeek(maskP), "LineWidth", 1.0);
                plot(dm.Date(maskP), dm.smaFast(maskP), "LineWidth", 1.0);
                plot(dm.Date(maskP), dm.smaSlow(maskP), "LineWidth", 1.0);
                plot(dm.Date(maskP), dm.smaLongTerm(maskP), "LineWidth", 1.2);
        
                % Trade markers (windowed)
                TL = tr.TradeLog;
                if ~isempty(TL)
                    mTL = (TL.Time >= win0) & (TL.Time <= win1);
        
                    isLongEntry  = mTL & TL.Action=="ENTER" & TL.PosAfter== 1;
                    isLongExit   = mTL & TL.Action=="EXIT"  & TL.PosBefore==1;
                    isShortEntry = mTL & TL.Action=="ENTER" & TL.PosAfter==-1;
                    isShortExit  = mTL & TL.Action=="EXIT"  & TL.PosBefore==-1;
        
                    scatter(TL.Time(isLongEntry),  TL.Price(isLongEntry),  60, '^', 'filled');
                    scatter(TL.Time(isLongExit),   TL.Price(isLongExit),   60, 'v', 'filled');
                    scatter(TL.Time(isShortEntry), TL.Price(isShortEntry), 60, 'v', 'filled');
                    scatter(TL.Time(isShortExit),  TL.Price(isShortExit),  60, '^', 'filled');
                end
        
                % Stop markers (windowed)
                if ~isempty(tr.StopLog)
                    mST = (tr.StopLog.Time >= win0) & (tr.StopLog.Time <= win1);
                    scatter(tr.StopLog.Time(mST), tr.StopLog.StopPx(mST), 80, 'x', 'LineWidth', 1.5);
                end
        
                % Force xlim to window (핵심!)
                xlim([win0 win1]);
        
                legend(["Close","SMA5","SMA20","SMA40","SMA180", ...
                        "Long Entry","Long Exit","Short Entry","Short Exit","Stop"], ...
                        "Location","best");
        
                title(sprintf("Price & MA (%s ~ %s)", datestr(win0), datestr(win1)));
                hold off;
        
                % ===== Tile 2: Equity & Position (windowed) =====
                nexttile(2); grid on;
        
                yyaxis left
                if ~isempty(tr.EqCurve) && any(maskE)
                    plot(tEq(maskE), tr.EqCurve.Equity(maskE), "LineWidth", 1.2);
                end
                ylabel("Equity");
        
                yyaxis right
                if ~isempty(tr.PosSeries) && any(maskS)
                    stairs(tPos(maskS), tr.PosSeries.Pos(maskS), "LineWidth", 1.2);
                end
                ylabel("Pos");
                yticks([-1 0 1]);
        
                xlim([win0 win1]);
                title("Equity & Position");
            end
        end

        function set_simulation_window(this, startDate, endDate)
            arguments
                this
                startDate (1,1) datetime
                endDate   (1,1) datetime
            end
            if endDate < startDate
                error("backtest_engine:BadWindow", "EndDate가 StartDate보다 빠릅니다.");
            end
            this.StartDate = startDate;
            this.EndDate   = endDate;
        end


        function eqEnd = get_trader_equity_end(this, tr)
            %#ok<INUSD>
            % Robust equity end accessor (prefers valuation curve if present)
            eqEnd = NaN;
            % 1) Accounting valuation curve
            try
                if isprop(tr,'ValCurve') && ~isempty(tr.ValCurve) && any(tr.ValCurve.Properties.VariableNames=="EquityClose")
                    eqEnd = tr.ValCurve.EquityClose(end);
                    return;
                end
            catch
            end
            % 2) Equity curve timetable
            try
                if isprop(tr,'EqCurve') && ~isempty(tr.EqCurve) && any(tr.EqCurve.Properties.VariableNames=="Equity")
                    eqEnd = tr.EqCurve.Equity(end);
                    return;
                end
            catch
            end
            % 3) Legacy scalar property
            try
                if isprop(tr,'Equity')
                    eqEnd = tr.Equity;
                    return;
                end
            catch
            end
        end
    end


    methods (Access=private)
        function r = stt(this, dt)
            if dt <= datetime(2024,12,31)
                r = this.STT_2024;
            else
                r = this.STT_2025;
            end
        end

        function sh = make_sheet_name(~, s)
            % Ensure 'Sheet' is a valid char row vector for Excel:
            % - must be char
            % - must be <= 31 chars
            % - cannot contain: : \ / ? * [ ]
            % - cannot be empty
        
            if isstring(s), s = char(s); end
            if ~ischar(s), s = char(string(s)); end
        
            s = strtrim(s);
        
            % Replace invalid characters with '_'
            s = regexprep(s, '[:\\/\?\*\[\]]', '_');
        
            % Excel also dislikes leading/trailing apostrophes sometimes
            s = regexprep(s, '''', '_');
        
            if isempty(s)
                s = 'Sheet';
            end
        
            % Truncate to 31 chars
            if numel(s) > 31
                s = s(1:31);
            end
        
            sh = s; % char
        end

    end
end
