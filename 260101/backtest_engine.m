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
        function [dtSeries, eqSeries] = run_single_fast(this, tr, startDate, endDate)
        %RUN_SINGLE_FAST  Fast single-trader simulation for optimization (index-based step).
        % - Calls tr.step(tIdx, this) where tIdx is index into tr.DM arrays.
        % - Temporarily disables curve logging by moving this.StartDate/EndDate out of range.
        %
        % Outputs:
        %   dtSeries : datetime column vector
        %   eqSeries : double column vector (tr.Equity after each step)
        
            dm = tr.DM;
        
            % --- get date vector from DM (best effort) ---
            if isprop(dm, "Dates")
                dtAll = dm.Dates;
            elseif isprop(dm, "dt")
                dtAll = dm.dt;
            elseif isprop(dm, "Date")
                dtAll = dm.Date;
            else
                error("run_single_fast:NoDates", "DM에 Dates/dt/Date 벡터가 없습니다.");
            end
        
            if ~isdatetime(dtAll)
                try
                    dtAll = datetime(dtAll);
                catch
                    dtAll = datetime(string(dtAll));
                end
            end
        
            if nargin < 3 || isempty(startDate); startDate = dtAll(1); end
            if nargin < 4 || isempty(endDate);   endDate   = dtAll(end); end
        
            % --- find index range ---
            i0 = find(dtAll >= startDate, 1, "first");
            i1 = find(dtAll <= endDate,   1, "last");
            if isempty(i0) || isempty(i1) || i1 < i0
                dtSeries = datetime.empty(0,1);
                eqSeries = zeros(0,1);
                return;
            end
        
            % step() 내부에서 dm.Open(t+1) 같은 접근이 있으면 t는 (N-1)까지만 안전
            nAll = numel(dtAll);
            i1step = min(i1, nAll-1);
            if i1step < i0
                dtSeries = datetime.empty(0,1);
                eqSeries = zeros(0,1);
                return;
            end
        
            nSteps = i1step - i0 + 1;
            dtSeries = dtAll(i0:i1step);
            dtSeries = dtSeries(:);
            eqSeries = zeros(nSteps,1);
        
            % --- reset trader state for this trial ---
            % optimize_trader_params에서 initial equity를 고정해 넘기고 있다면
            % 여기서 reset_for_run()은 1-인자/2-인자 모두 try합니다.
            if ismethod(tr, "reset_for_run")
                try
                    tr.reset_for_run(); % 현재 Equity 기준 리셋
                catch
                    try
                        tr.reset_for_run(tr.get_equity()); % 혹시 인자 필요
                    catch
                        tr.reset_for_run; %#ok<VUNUS>
                    end
                end
            end
        
            % --- temporarily disable append_curves() inside trader.step() ---
            oldStart = this.StartDate;
            oldEnd   = this.EndDate;
            try
                % step()에서: if dt >= StartDate && dt <= EndDate then append_curves()
                % → StartDate를 미래로 보내면 조건이 false가 되어 커브 누적 비용을 크게 줄임
                this.StartDate = datetime(9999,1,1);
                this.EndDate   = datetime(9999,12,31);
            catch
                % 만약 StartDate/EndDate가 없거나 set 불가면 무시
            end
        
            % --- main loop (index-based) ---
            for k = 1:nSteps
                tIdx = i0 + (k-1);
        
                % 실제 시그니처: step(this, t, execModel)
                tr.step(tIdx, this);
        
                % fast objective용 equity snapshot
                % (현재 trader 구현은 Equity를 mark-to-market으로 갱신하는 구조)
                eqSeries(k) = tr.get_equity();
            end
        
            % --- restore engine dates ---
            try
                this.StartDate = oldStart;
                this.EndDate   = oldEnd;
            catch
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
        
            % ---- Put active traders back (since we used a local variable) ----
            % Note: traders array is a copy of handles, so underlying objects updated.
        end        function rep = report(this)
            % Summary per trader (close-based valuation preferred)
            n = numel(this.Master.Traders);
            rep = table('Size',[n 7], ...
                'VariableTypes', ["string","string","double","double","double","double","double"], ...
                'VariableNames', ["Ticker","Name","EquityEnd","TotRet","CAGR","Trades","Stops"]);

            for i = 1:n
                tr = this.Master.Traders(i);

                % Prefer accounting valuation curve (Close-based)
                eq = [];
                dt = [];
                if isprop(tr,'ValCurve') && ~isempty(tr.ValCurve) && any(string(tr.ValCurve.Properties.VariableNames)=="EquityClose")
                    eq = tr.ValCurve.EquityClose;
                    dt = tr.ValCurve.Properties.RowTimes;
                elseif isprop(tr,'EqCurve') && ~isempty(tr.EqCurve) && any(string(tr.EqCurve.Properties.VariableNames)=="Equity")
                    eq = tr.EqCurve.Equity;
                    dt = tr.EqCurve.Properties.RowTimes;
                end

                if isempty(eq)
                    eqEnd = tr.get_equity();
                    TotRet = 0;
                    CAGR = 0;
                else
                    eqEnd = eq(end);
                    if eq(1) <= 0
                        TotRet = NaN;
                        CAGR = NaN;
                    else
                        TotRet = eqEnd/eq(1) - 1;
                        nYears = max(days(dt(end)-dt(1))/365.25, eps);
                        CAGR = (eqEnd/eq(1))^(1/nYears) - 1;
                    end
                end

                rep.Ticker(i) = string(tr.DM.Ticker);
                rep.Name(i)   = string(tr.DM.Name);
                rep.EquityEnd(i) = eqEnd;

                rep.TotRet(i) = TotRet;
                rep.CAGR(i)   = CAGR;

                if isprop(tr,'TradeLog') && ~isempty(tr.TradeLog)
                    rep.Trades(i) = height(tr.TradeLog);
                else
                    rep.Trades(i) = 0;
                end
                if isprop(tr,'StopLog') && ~isempty(tr.StopLog)
                    rep.Stops(i) = height(tr.StopLog);
                else
                    rep.Stops(i) = 0;
                end
            
        


                rep.Ticker(i) = tr.DM.Ticker;
                rep.Name(i)   = tr.DM.Name;
                rep.EquityEnd(i) = tr.Equity;
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
        function plot(this, varargin)
            % plot(this, "FullDetail", true/false, ...)
            %
            % Performance-aware plotting:
            %   - Close and Equity are always plotted in full detail.
            %   - Moving averages can be subsampled automatically when window > 1 year.
            %   - Position is drawn as a stair plot; when not FullDetail, it is compressed to
            %     change-points only (much faster and visually identical for regime plots).
            %
            % Options (name-value):
            %   "FullDetail"        : if true, disables subsampling (plots everything)
            %   "AutoSubsampleYears": if window exceeds this (default 1), subsample MAs unless FullDetail
            %   "MaxMAPoints"       : target max number of points for MA lines when subsampling (default 3000)
            %   "CompressPosition"  : if true, compress position to change points when not FullDetail (default true)

            ip = inputParser;
            addParameter(ip, "FullDetail", false);
            addParameter(ip, "AutoSubsampleYears", 1.0);
            addParameter(ip, "MaxMAPoints", 3000);
            addParameter(ip, "CompressPosition", true);
            parse(ip, varargin{:});
            Opt = ip.Results;

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

                idxP = find(maskP);  % Close is always full-detail
                if isempty(idxP)
                    continue;
                end

                % ---- subsampling decision for MA ----
                winYears = days(win1 - win0) / 365.25;
                doSubMA = (~Opt.FullDetail) && (winYears > Opt.AutoSubsampleYears);

                idxMA = idxP;
                if doSubMA
                    k = ceil(numel(idxMA) / max(1, Opt.MaxMAPoints));
                    k = max(1, k);
                    idxMA = idxMA(1:k:end);
                end

                % ===== Figure =====
                figure("Name", sprintf("%s %s", char(dm.Ticker), char(dm.Name)), "Color","w");
                tiledlayout(2,1,"TileSpacing","compact","Padding","compact");

                % ===== Tile 1: Price & MAs (windowed) =====
                nexttile(1); hold on; grid on;

                % Price (full)
                plot(dm.Date(idxP), dm.Close(idxP), "LineWidth", 1.2);

                % MAs (possibly subsampled)
                if ~isempty(dm.smaWeek)
                    plot(dm.Date(idxMA), dm.smaWeek(idxMA), "LineWidth", 1.0);
                end
                if ~isempty(dm.smaFast)
                    plot(dm.Date(idxMA), dm.smaFast(idxMA), "LineWidth", 1.0);
                end
                if ~isempty(dm.smaSlow)
                    plot(dm.Date(idxMA), dm.smaSlow(idxMA), "LineWidth", 1.0);
                end
                if isprop(dm, "smaLongTerm") && ~isempty(dm.smaLongTerm)
                    plot(dm.Date(idxMA), dm.smaLongTerm(idxMA), "LineWidth", 1.0);
                end

                % Trade markers (windowed)
                if ~isempty(tr.TradeLog)
                    TL = tr.TradeLog;
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

                % Force xlim to window
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
                    if Opt.FullDetail || ~Opt.CompressPosition
                        stairs(tPos(maskS), tr.PosSeries.Pos(maskS), "LineWidth", 1.2);
                    else
                        % Compress to change points (fast, visually equivalent for stairs)
                        p = tr.PosSeries.Pos(maskS);
                        tt = tPos(maskS);
                        if ~isempty(p)
                            d = [true; diff(p) ~= 0];
                            idx = find(d);
                            idx(end+1) = numel(p); %#ok<AGROW>
                            idx = unique(idx);
                            stairs(tt(idx), p(idx), "LineWidth", 1.2);
                        end
                    end
                end
                ylabel("Pos");
                yticks([-1 0 1]);

                xlim([win0 win1]);
                title("Equity & Position");
            end
        end


        
        function [bestParams, bestScore, results] = optimize_trader_params(this, traderIdx, searchSpace, varargin)
            % Optimize trader hyperparameters by maximizing end equity (Close-based),
            % with MaxDD penalty.
            %
            % traderIdx: index of trader in Master.Traders
            % searchSpace: scalar struct of parameter -> vector/cell/string candidate values
            % Example:
            %   S = struct(); S.SpreadEnterPct=[0.002 0.003]; S.EnableShort=[false true];
            %
            % Name-Value:
            %   "MaxEvals" (default 250)
            %   "Verbose"  (default true)
            %   "Seed"     (default 1)
            %   "DDPenalty" (default 0.5)
            %   "UseLogEquity" (default true)

            % ---- Parse options (NO arguments block) ----
            ip = inputParser;
            addParameter(ip, "MaxEvals", 250);
            addParameter(ip, "Verbose", true);
            addParameter(ip, "Seed", 1);
            addParameter(ip, "DDPenalty", 0.5);
            addParameter(ip, "UseLogEquity", true);
            parse(ip, varargin{:});
            Opt = ip.Results;

            if traderIdx < 1 || traderIdx > numel(this.Master.Traders)
                error("backtest_engine:BadTraderIdx","유효하지 않은 traderIdx 입니다.");
            end
            tr = this.Master.Traders(traderIdx);

            if ~isstruct(searchSpace) || ~isscalar(searchSpace)
                error("backtest_engine:BadSearchSpace","searchSpace는 scalar struct여야 합니다. (S.Param = [values] 형태)");
            end

            % ---- build candidate list ----
            [candList, totalComb] = this.build_candidates(searchSpace, Opt.MaxEvals, Opt.Seed);

            if Opt.Verbose
                fprintf("Optimization window: %s ~ %s\n", datestr(this.StartDate), datestr(this.EndDate));
                fprintf("[OPT] evaluating %d candidates (out of %g combinations)\n", numel(candList), totalComb);
            end

            % Fixed initial equity (for TotRet/CAGR denominator)
            fixedInitEq = tr.get_equity();

            bestScore  = -Inf;
            bestParams = struct();

            scores  = nan(numel(candList),1);
            eqEnds  = nan(numel(candList),1);
            maxDDs  = nan(numel(candList),1);
            cagrs   = nan(numel(candList),1);
            totRets = nan(numel(candList),1);
            pjson   = strings(numel(candList),1);

            for k = 1:numel(candList)
                params = candList{k};

                % Apply hyperparams
                if ismethod(tr,"set_hparams")
                    tr.set_hparams(params);
                else
                    % fallback: set public properties if exist
                    fn = fieldnames(params);
                    for j=1:numel(fn)
                        if isprop(tr, fn{j})
                            tr.(fn{j}) = params.(fn{j});
                        end
                    end
                end

                % Reset trader state for a clean trial (IMPORTANT)
                if ismethod(tr,"reset_for_run")
                    tr.reset_for_run(fixedInitEq);
                end

                % Speed: disable logging during optimization
                if isprop(tr,"LogCurves"); tr.LogCurves = false; end
                if isprop(tr,"LogTrades"); tr.LogTrades = false; end
                if isprop(tr,"LogStops");  tr.LogStops  = false; end

                % Run fast single-trader backtest
                [dtSeries, eqSeries] = this.run_single_fast(tr, this.StartDate, this.EndDate);

                if isempty(eqSeries)
                    eqSeries = fixedInitEq;
                    dtSeries = datetime.empty(0,1);
                end

                % End equity
                eqEnd = eqSeries(end);

                % MaxDD
                maxDD = this.compute_maxdd_series(eqSeries);

                % CAGR (annualized, based on dtSeries)
                cagr = NaN;
                if ~isempty(dtSeries)
                    yrs = days(dtSeries(end) - dtSeries(1)) / 365.25;
                    if yrs > 0
                        cagr = (eqEnd / fixedInitEq)^(1/yrs) - 1;
                    end
                end

                totRet = (eqEnd / fixedInitEq) - 1;

                % Restore logging for potential later reporting
                if isprop(tr,"LogCurves"); tr.LogCurves = true; end
                if isprop(tr,"LogTrades"); tr.LogTrades = true; end
                if isprop(tr,"LogStops");  tr.LogStops  = true; end


                % Score
                if Opt.UseLogEquity
                    base = log(max(eqEnd, realmin));
                else
                    base = eqEnd;
                end
                score = base - Opt.DDPenalty * maxDD;

                scores(k)  = score;
                eqEnds(k)  = eqEnd;
                maxDDs(k)  = maxDD;
                cagrs(k)   = cagr;
                totRets(k) = totRet;
                pjson(k)   = string(jsonencode(params));

                if score > bestScore
                    bestScore  = score;
                    bestParams = params;
                    if Opt.Verbose
                        fprintf("[OPT] new best i=%d score=%.6f eq=%.3e maxDD=%.3f\n", k, bestScore, eqEnd, maxDD);
                    end
                end
            end

            results = table((1:numel(candList))', scores, eqEnds, totRets, cagrs, maxDDs, pjson, ...
                'VariableNames', {'Idx','Score','EquityEnd','TotRet','CAGR','MaxDD','ParamsJson'});
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

    end

    methods (Access=private)
        
        function [candList, totalComb] = build_candidates(this, searchSpace, MaxEvals, Seed) %#ok<INUSD>
            % Build candidate parameter structs.
            % If total combinations <= MaxEvals: full grid.
            % Else: random sampling (with replacement).
            f = fieldnames(searchSpace);
            nF = numel(f);
            if nF == 0
                candList = {struct()};
                totalComb = 1;
                return;
            end

            vals = cell(nF,1);
            nVals = zeros(nF,1);
            for i=1:nF
                v = searchSpace.(f{i});
                if isempty(v)
                    error("backtest_engine:BadSearchSpace","searchSpace.%s 가 비었습니다.", f{i});
                end
                if islogical(v) && isscalar(v)
                    v = [false true];
                end
                if isstring(v)
                    v = cellstr(v(:))';
                end
                if iscell(v)
                    vals{i} = v(:)'; 
                    nVals(i) = numel(vals{i});
                else
                    vals{i} = num2cell(v(:)'); 
                    nVals(i) = numel(vals{i});
                end
            end

            totalComb = prod(double(nVals));
            maxE = min(MaxEvals, totalComb);

            if totalComb <= maxE
                % Full grid
                idxGrid = cell(nF,1);
                for i=1:nF
                    idxGrid{i} = 1:nVals(i);
                end
                [G{1:nF}] = ndgrid(idxGrid{:}); %#ok<CCAT>
                nC = numel(G{1});
                candList = cell(nC,1);
                for k=1:nC
                    s = struct();
                    for i=1:nF
                        s.(f{i}) = vals{i}{ G{i}(k) };
                    end
                    candList{k} = s;
                end
            else
                % Random sample
                rng(Seed);
                candList = cell(maxE,1);
                for k=1:maxE
                    s = struct();
                    for i=1:nF
                        j = randi(nVals(i));
                        s.(f{i}) = vals{i}{j};
                    end
                    candList{k} = s;
                end
            end
        end

        function maxDD = compute_maxdd_series(~, eqSeries)
            % Max drawdown from equity vector
            if isempty(eqSeries)
                maxDD = NaN;
                return;
            end
            eq = double(eqSeries(:));
            eq(~isfinite(eq)) = NaN;
            if all(isnan(eq)) || numel(eq) < 2
                maxDD = 0;
                return;
            end
            % forward fill NaNs
            for i=2:numel(eq)
                if isnan(eq(i)), eq(i) = eq(i-1); end
            end
            if isnan(eq(1))
                eq(1) = eq(find(~isnan(eq),1,'first'));
            end
            peak = cummax(eq);
            dd = 1 - eq ./ peak;
            dd(~isfinite(dd)) = 0;
            maxDD = max(dd);
        end

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
