classdef portfolio_backtest_engine < handle
    % portfolio_backtest_engine
    %
    % Shared-cash portfolio backtest engine.
    %
    % 핵심:
    %  - 체결(Open)과 평가(Close)를 분리
    %  - 수수료/세금/마진/차입비용은 portfolio_account 단에서 반영
    %  - 주문 거부 시(현금/수수료/세금/마진), 반복적으로 다운사이징하여 가능한 수량을 탐색
    %
    % MATLAB 호환성:
    %  - arguments 블록 미사용
    %  - 메서드 내부 nested function 미사용

    properties
        % If true, prints lightweight progress/debug messages during run()
        Verbose = false

        TradingDays = 252
        StartDate = datetime(1900,1,1)
        EndDate   = datetime(2100,12,31)

        Master   % portfolio_master
        Exec     % null_exec_model

        % When true, sizing uses current equity each day. Otherwise uses InitialCapital.
        UseDynamicSizing = true

        % When false (default), the engine sizes only on entry/flip and keeps quantity
        % unchanged while holding the same direction. This matches the legacy
        % single-ticker behavior (no daily rebalancing).
        RebalanceWhileHolding = false

        % 'CLOSE' or 'NEXT_OPEN'
        ValuationMode = 'CLOSE'

        % Apply ticker_trader.PositionFrac at entry sizing only
        UseEntryPositionFrac = true

        % Reset trader states at the beginning of each run (recommended for optimization)
        ResetTradersEachRun = true

        % Warnings on suspicious states
        EnableSanityWarnings = true

        % Downsize loop parameters (fix for fee/tax cash shortage)
        DownsizeMaxIter = 12
        DownsizeFactor  = 0.98

        % Engine-level decision log (only rejections; lightweight)
        LogRejections = true
        RejectionLog

        % Debug info for last run
        LastRunInfo = struct()
    end

    methods
        function this = portfolio_backtest_engine(master)
            if nargin < 1 || isempty(master) || ~isa(master,'portfolio_master')
                error('portfolio_backtest_engine:BadMaster','master must be a portfolio_master');
            end
            this.Master = master;
            this.Exec = null_exec_model();
            this.LastRunInfo = struct('ExecutedTrades',0,'SignalTrades',0,'RejectedOrders',0,'ZeroQtySignals',0);
            this.RejectionLog = table();
            this.RejectionLog = table('Size',[0 9],'VariableTypes',{'datetime','string','double','double','double','double','double','double','string'},'VariableNames',{'Time','Symbol','DesiredPos','CurQty','TargetQty','FinalQty','Px','Iter','Note'});
        end

        function run(this)
            inst = this.Master.Instruments;
            n = numel(inst);
            if n == 0
                error('portfolio_backtest_engine:NoInstrument','유니버스가 비어 있습니다.');
            end
            if this.EndDate < this.StartDate
                error('portfolio_backtest_engine:BadWindow','EndDate가 StartDate보다 빠릅니다.');
            end

            % --- Build common date grid (intersection across instruments) ---
            commonDates = inst(1).DM.Date;
            commonDates = commonDates(commonDates >= this.StartDate & commonDates <= this.EndDate);
            for i = 2:n
                dti = inst(i).DM.Date;
                dti = dti(dti >= this.StartDate & dti <= this.EndDate);
                commonDates = intersect(commonDates, dti);
            end
            commonDates = sort(commonDates);
            if isempty(commonDates)
                error('portfolio_backtest_engine:NoCommonDates','요청 기간에서 공통 날짜가 없습니다.');
            end

            % date->index mapping per instrument
            idxMap = cell(n,1);
            for i=1:n
                [~, loc] = ismember(commonDates, inst(i).DM.Date);
                idxMap{i} = loc;
            end

            % --- Reset shared portfolio ---
            this.Master.reset();
            this.Exec.StartDate = this.StartDate;
            this.Exec.EndDate   = this.EndDate;

            % --- Build specMap (symbol->spec) ---
            specMap = containers.Map('KeyType','char','ValueType','any');
            for i=1:n
                sym = char(inst(i).Spec.Symbol);
                specMap(sym) = inst(i).Spec;
            end

            % --- Reset each trader at run start (important for optimization) ---
            if this.ResetTradersEachRun
                for i=1:n
                    tr = inst(i).Trader;
                    if ismethod(tr,'reset_for_run')
                        tr.reset_for_run(0);
                    else
                        portfolio_backtest_engine.force_trader_state(tr,0);
                    end
                end
            end

            % --- Init price map using first day's Close ---
            priceInit = containers.Map('KeyType','char','ValueType','double');
            for i=1:n
                sym = char(inst(i).Spec.Symbol);
                t0 = idxMap{i}(1);
                if t0 > 0
                    priceInit(sym) = double(inst(i).DM.Close(t0));
                end
            end
            this.Master.Portfolio.update_last_prices(priceInit);

            rejCount = 0;
            zeroQtySignals = 0;
            executedTrades = 0;
            signalTrades = 0;
            lastEqWarn = NaN;

            % --- Main loop ---
            for k = 1:numel(commonDates)
                dt = commonDates(k);

                % Build price maps for this date (Open/Close) and next-open (optional)
                openPx  = containers.Map('KeyType','char','ValueType','double');
                closePx = containers.Map('KeyType','char','ValueType','double');
                nextOpenPx = containers.Map('KeyType','char','ValueType','double');

                for i=1:n
                    spec = inst(i).Spec;
                    traderId = "";
                    if isfield(inst(i), 'TraderId')
                        traderId = string(inst(i).TraderId);
                    elseif isprop(spec,'TraderId')
                        traderId = string(spec.TraderId);
                    end
                    sym = char(spec.Symbol);
                    t = idxMap{i}(k);
                    if t <= 0
                        continue;
                    end
                    openPx(sym)  = double(inst(i).DM.Open(t));
                    closePx(sym) = double(inst(i).DM.Close(t));

                    if strcmpi(this.ValuationMode,'NEXT_OPEN') && k < numel(commonDates)
                        t2 = idxMap{i}(k+1);
                        if t2 > 0
                            nextOpenPx(sym) = double(inst(i).DM.Open(t2));
                        end
                    end
                end

                % 1) Run each trader step (signal generation)
                for i=1:n
                    tr = inst(i).Trader;
                    t = idxMap{i}(k);
                    if t <= 0
                        continue;
                    end
                    % The trader uses its own DM index.
                    tr.step(t, this.Exec);
                end

                % 2) Execute to match desired trader Pos
                for i=1:n
                    spec = inst(i).Spec;
                    traderId = "";
                    if isfield(inst(i), 'TraderId')
                        traderId = string(inst(i).TraderId);
                    elseif isprop(spec,'TraderId')
                        traderId = string(spec.TraderId);
                    end
                    sym  = char(spec.Symbol);
                    tr   = inst(i).Trader;

                    if ~isKey(openPx, sym)
                        continue;
                    end
                    px = openPx(sym);
                    if ~isfinite(px) || px <= 0
                        continue;
                    end

                    % Current executed position from portfolio
                    p = this.Master.Portfolio.get_position(sym);
                    curQty = double(p.Qty);

                    % Desired position from trader
                    desiredPos = double(tr.Pos);

                    % Safety enforcement: short max holding days (e.g., KRX 90-day cover rule)
                    % Even if trader does not implement the rule, the engine can force desiredPos -> 0.
                    if desiredPos < 0 && isprop(spec, 'EnforceShortMaxHold') && logical(spec.EnforceShortMaxHold)
                        if isprop(spec, 'ShortMaxHoldDays') && isfinite(double(spec.ShortMaxHoldDays))
                            try
                                if isprop(tr, 'EntryDate') && ~isnat(tr.EntryDate)
                                    heldCal = days(dt - tr.EntryDate);
                                    if heldCal >= double(spec.ShortMaxHoldDays)
                                        desiredPos = 0; % force cover
                                    end
                                end
                            catch
                                % ignore
                            end
                        end
                    end

                    % Count signal changes (for debug only)
                    % If trader flips Pos relative to current executed sign, treat as signal trade.
                    curPosSign = sign(curQty);
                    if curPosSign ~= sign(desiredPos)
                        signalTrades = signalTrades + 1;
                    end

                    % Compute target quantity
                    % Default behavior: size on entry/flip only (no daily rebalancing)
                    targetQty = 0;
                    if desiredPos ~= 0
                        if ~this.RebalanceWhileHolding && curPosSign ~= 0 && sign(desiredPos) == curPosSign
                            % Holding same direction: keep quantity as-is
                            targetQty = curQty;
                        else
                            % base equity for sizing
                            if this.UseDynamicSizing
                                eqNow = this.Master.Portfolio.compute_equity(closePx, specMap);
                            else
                                eqNow = this.Master.InitialCapital;
                            end
                            maxNotional = double(spec.MaxNotionalFrac) * eqNow;

                            % apply PositionFrac at entry
                            if this.UseEntryPositionFrac && desiredPos ~= 0 && curPosSign == 0
                                if isprop(tr,'PositionFrac')
                                    maxNotional = maxNotional * double(tr.PositionFrac);
                                end
                            end

                            % convert to contracts/shares
                            denom = px * double(spec.Multiplier);
                            if denom > 0
                                targetAbs = floor(maxNotional / denom);
                            else
                                targetAbs = 0;
                            end

                            if targetAbs <= 0
                                targetQty = 0;
                            else
                                targetQty = sign(desiredPos) * targetAbs;
                            end
                        end
                    end

                    if targetQty == curQty
                        continue;
                    end

                    if abs(targetQty) == 0 && abs(curQty) == 0
                        continue;
                    end

                    % If sizing yields zero though trader wants position, count it
                    if desiredPos ~= 0 && targetQty == 0
                        zeroQtySignals = zeroQtySignals + 1;
                    end

                    % Execute with downsizing loop to avoid reject due to fees/taxes/margin
                    [ok, finalTargetQty, iterUsed] = this.set_target_qty_downsize(dt, sym, targetQty, px, spec, specMap, traderId);
                    if ok
                        executedTrades = executedTrades + 1;

% Notify trader of actual fill (for log consistency)
try
    if ismethod(tr, 'on_portfolio_fill') && ismethod(tr, 'enable_external_accounting')
        % Determine action type from qty change
        qtyBefore = curQty;
        qtyAfter  = finalTargetQty;
        act = "REBALANCE";
        if qtyBefore == 0 && qtyAfter ~= 0
            act = "ENTER";
        elseif qtyBefore ~= 0 && qtyAfter == 0
            act = "EXIT";
        elseif sign(qtyBefore) ~= sign(qtyAfter)
            act = "FLIP";
        end
        tr.on_portfolio_fill(dt, act, px, sign(qtyBefore), sign(qtyAfter), "FILL");
    end
catch
end

                        % Sync trader state to executed position sign
                        newP = this.Master.Portfolio.get_position(sym);
                        portfolio_backtest_engine.force_trader_state(tr, sign(double(newP.Qty)));
                    else
                        rejCount = rejCount + 1;

                        if this.LogRejections
                            note = "REJECT";
                            if isempty(this.RejectionLog) || width(this.RejectionLog)==0
                                this.RejectionLog = table(dt, string(traderId), string(sym), desiredPos, curQty, targetQty, finalTargetQty, px, iterUsed, string(note), ...
                                    'VariableNames', {'Time','TraderId','Symbol','DesiredPos','CurQty','TargetQty','FinalQty','Px','Iter','Note'});
                            else
                                this.RejectionLog = [this.RejectionLog; {dt, string(traderId), string(sym), desiredPos, curQty, targetQty, finalTargetQty, px, iterUsed, string(note)}]; %#ok<AGROW>
                            end
                        end

                        % Roll back trader to executed position sign to keep consistency
                        portfolio_backtest_engine.force_trader_state(tr, sign(curQty));
                    end

                    %#ok<NASGU>
                    finalTargetQty = finalTargetQty;
                end

                % 3) Apply borrow cost daily (using close prices)
                this.Master.Portfolio.apply_borrow_cost(dt, closePx, specMap, this.TradingDays);

                % 4) Append equity curve (portfolio_account buffers internally)
                valPx = closePx;
                if strcmpi(this.ValuationMode,'NEXT_OPEN')
                    if nextOpenPx.Count == 0
                        % 마지막 날: close로 평가
                        this.Master.Portfolio.append_equity_curve(dt, closePx, specMap);
                        valPx = closePx;
                    else
                        this.Master.Portfolio.append_equity_curve(dt, nextOpenPx, specMap);
                        valPx = nextOpenPx;
                    end
                else
                    this.Master.Portfolio.append_equity_curve(dt, closePx, specMap);
                    valPx = closePx;
                end

                % Optional sanity warning (avoid EquityCurve access inside loop for speed)
                if this.EnableSanityWarnings
                    eqNow = this.Master.Portfolio.compute_equity(valPx, specMap);
                    if isfinite(lastEqWarn) && abs(eqNow - lastEqWarn) < 1e-9 && executedTrades > 0
                        % keep silent (optimizer prints its own warnings)
                    end
                    lastEqWarn = eqNow;
                end

            end

            % Flush any buffered logs for deterministic post-run inspection
            try
                if ismethod(this.Master.Portfolio,'flush_all')
                    this.Master.Portfolio.flush_all();
                end
            catch
            end
            for i=1:n
                try
                    tr = inst(i).Trader;
                    if ismethod(tr,'flush_buffers')
                        tr.flush_buffers();
                    end
                catch
                end
            end

            this.LastRunInfo = struct('ExecutedTrades',executedTrades, ...
                'SignalTrades',signalTrades, 'RejectedOrders',rejCount, 'ZeroQtySignals',zeroQtySignals);
        end

        function L = get_logs(this)
            % Return a lightweight snapshot of engine/portfolio logs for testing
            L = struct();
            L.LastRunInfo = this.LastRunInfo;
            L.RejectionLog = this.RejectionLog;
            try
                L.PortfolioTradeLog = this.Master.Portfolio.TradeLog;
                L.EquityCurve = this.Master.Portfolio.EquityCurve;
            catch
                L.PortfolioTradeLog = table();
                L.EquityCurve = timetable();
            end
        end


        function plot(this, varargin)
            % plot(this, "FullDetail", true/false, ...)
            %
            % Performance-aware plotting (modeled after backtest_engine.plot):
            %   - Close & Equity are plotted in full detail.
            %   - Moving averages can be subsampled automatically when window is long.
            %   - Position is drawn as stairs; by default it is compressed to change points only.
            %
            % Options (name-value):
            %   "FullDetail"        : if true, disables subsampling/compression (plots everything)
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

            inst = this.Master.Instruments;
            n = numel(inst);
            if n == 0
                return;
            end

            % Requested window (may extend beyond available data)
            win0_req = this.StartDate;
            win1_req = this.EndDate;

            % Equity curve (portfolio-level)
            EC = this.Master.Portfolio.EquityCurve;
            if isempty(EC) || height(EC) == 0
                return;
            end
            tEq = EC.Properties.RowTimes;
            % Equity mask is computed later with an effective per-figure window.
            % (Do not pre-mask with requested window; data may start later.)

            % Trade log (portfolio-level)
            TLp = this.Master.Portfolio.TradeLog;

            for i = 1:n
                dm = inst(i).DM;
                spec = inst(i).Spec;
                    traderId = "";
                    if isfield(inst(i), 'TraderId')
                        traderId = string(inst(i).TraderId);
                    elseif isprop(spec,'TraderId')
                        traderId = string(spec.TraderId);
                    end
                sym = char(spec.Symbol);
                if isempty(sym)
                    sym = char(dm.Ticker);
                end

                % ===== Effective plotting window (intersection of requested + available) =====
                dm0 = dm.Date(1);
                dm1 = dm.Date(end);
                eq0 = tEq(1);
                eq1 = tEq(end);

                win0 = max([win0_req; dm0; eq0]);
                win1 = min([win1_req; dm1; eq1]);
                if win1 <= win0
                    continue;
                end

                % ===== window mask for price =====
                maskP = (dm.Date >= win0) & (dm.Date <= win1);
                idxP = find(maskP);
                if isempty(idxP)
                    continue;
                end

                % ---- subsampling decision for MA ----
                winYears = days(win1 - win0) / 365.25;
                doSubMA = (~Opt.FullDetail) && (winYears > Opt.AutoSubsampleYears);

                idxMA = idxP;
                if doSubMA
                    ksub = ceil(numel(idxMA) / max(1, Opt.MaxMAPoints));
                    ksub = max(1, ksub);
                    idxMA = idxMA(1:ksub:end);
                end

                % ===== Figure =====
                figure("Name", sprintf("%s %s", sym, char(dm.Name)), "Color","w");
                tiledlayout(2,1,"TileSpacing","compact","Padding","compact");

                % ===== Tile 1: Price & MAs =====
                nexttile(1); hold on; grid on;

                plot(dm.Date(idxP), dm.Close(idxP), "LineWidth", 1.2);

                % MAs (possibly subsampled)
                if isprop(dm, "smaWeek") && ~isempty(dm.smaWeek)
                    plot(dm.Date(idxMA), dm.smaWeek(idxMA), "LineWidth", 1.0);
                end
                if isprop(dm, "smaFast") && ~isempty(dm.smaFast)
                    plot(dm.Date(idxMA), dm.smaFast(idxMA), "LineWidth", 1.0);
                end
                if isprop(dm, "smaSlow") && ~isempty(dm.smaSlow)
                    plot(dm.Date(idxMA), dm.smaSlow(idxMA), "LineWidth", 1.0);
                end
                if isprop(dm, "smaLongTerm") && ~isempty(dm.smaLongTerm)
                    plot(dm.Date(idxMA), dm.smaLongTerm(idxMA), "LineWidth", 1.0);
                end

                % Trade markers (portfolio executed trades)
                if ~isempty(TLp) && height(TLp) > 0
                    mTL = (TLp.Time >= win0) & (TLp.Time <= win1) & (TLp.Symbol == string(sym));
                    if any(mTL)
                        tl = TLp(mTL,:);
                        qtyBefore = tl.QtyAfter - tl.QtyDelta;

                        isLongEntry  = (qtyBefore == 0) & (tl.QtyAfter > 0);
                        isLongExit   = (tl.QtyAfter == 0) & (qtyBefore > 0);
                        isShortEntry = (qtyBefore == 0) & (tl.QtyAfter < 0);
                        isShortExit  = (tl.QtyAfter == 0) & (qtyBefore < 0);

                        if any(isLongEntry)
                            scatter(tl.Time(isLongEntry), tl.Price(isLongEntry), 60, '^', 'filled');
                        end
                        if any(isLongExit)
                            scatter(tl.Time(isLongExit), tl.Price(isLongExit), 60, 'v', 'filled');
                        end
                        if any(isShortEntry)
                            scatter(tl.Time(isShortEntry), tl.Price(isShortEntry), 60, 'v', 'filled');
                        end
                        if any(isShortExit)
                            scatter(tl.Time(isShortExit), tl.Price(isShortExit), 60, '^', 'filled');
                        end
                    end
                end

                xlim([win0 win1]);
                if win0 > win0_req || win1 < win1_req
                    title(sprintf("Price & MA (%s ~ %s)  [clipped]", datestr(win0), datestr(win1)));
                else
                    title(sprintf("Price & MA (%s ~ %s)", datestr(win0), datestr(win1)));
                end
                hold off;

                % ===== Tile 2: Equity & Position (sign) =====
                nexttile(2); grid on;

                yyaxis left
                maskE = (tEq >= win0) & (tEq <= win1);
                if any(maskE)
                    plot(tEq(maskE), EC.Equity(maskE), "LineWidth", 1.2);
                end
                ylabel("Equity");

                yyaxis right
                % Build compressed position sign series from portfolio trades
                [tPos, pPos] = portfolio_backtest_engine.build_pos_sign_series(TLp, sym, win0, win1);
                if ~isempty(tPos)
                    if Opt.FullDetail || ~Opt.CompressPosition
                        stairs(tPos, pPos, "LineWidth", 1.2);
                    else
                        d = [true; diff(pPos) ~= 0];
                        idx = find(d);
                        idx(end+1) = numel(pPos); %#ok<AGROW>
                        idx = unique(idx);
                        stairs(tPos(idx), pPos(idx), "LineWidth", 1.2);
                    end
                end
                ylabel("Pos");
                yticks([-1 0 1]);

                xlim([win0 win1]);
                title("Equity & Position");
            end
        end

    end

    methods (Access=private)
        function [ok, finalTargetQty, iterUsed] = set_target_qty_downsize(this, dt, sym, targetQty, px, spec, specMap, traderId)
            % Try to set target qty; if rejected, downsize target.
            ok = false;
            finalTargetQty = targetQty;
            iterUsed = 0;

            % quick reject for forbidden short
            if targetQty < 0 && ~spec.AllowShort
                ok = false;
                finalTargetQty = NaN;
                return;
            end

            iter = 0;
            tq = double(targetQty);
            while iter <= this.DownsizeMaxIter
                ok = this.Master.Portfolio.set_target_qty(dt, sym, tq, px, spec, specMap, traderId);
                if ok
                    finalTargetQty = tq;
                    iterUsed = iter;
                    return;
                end

                % if downsizing cannot proceed, stop
                if tq == 0
                    finalTargetQty = 0;
                    iterUsed = iter;
                    return;
                end

                % Downsize magnitude and keep direction
                tqAbs = floor(abs(tq) * this.DownsizeFactor);
                if tqAbs < 1
                    tq = 0;
                else
                    tq = sign(tq) * tqAbs;
                end

                iter = iter + 1;
            end

            finalTargetQty = tq;
            iterUsed = iter;

        end
    end

    methods (Static, Access=private)

        function [tPos, pPos] = build_pos_sign_series(TLp, sym, win0, win1)
            % Build a compressed position sign series (-1/0/+1) for a symbol
            % using portfolio TradeLog (executed trades).
            tPos = datetime.empty(0,1);
            pPos = double.empty(0,1);

            if nargin < 2
                return;
            end
            if nargin < 3 || isempty(win0)
                win0 = datetime(1900,1,1);
            end
            if nargin < 4 || isempty(win1)
                win1 = datetime(2100,12,31);
            end
            if isempty(TLp) || ~istable(TLp) || height(TLp) == 0
                tPos = [win0; win1];
                pPos = [0; 0];
                return;
            end

            symS = string(sym);
            tlAll = TLp(TLp.Symbol == symS, :);
            if isempty(tlAll)
                tPos = [win0; win1];
                pPos = [0; 0];
                return;
            end
            % ensure chronological
            [~,ord] = sort(tlAll.Time);
            tlAll = tlAll(ord,:);

            % position sign at window start (last trade before win0)
            pos0 = 0;
            idxPrev = find(tlAll.Time < win0, 1, 'last');
            if ~isempty(idxPrev)
                pos0 = sign(double(tlAll.QtyAfter(idxPrev)));
            end

            % trades in window
            mW = (tlAll.Time >= win0) & (tlAll.Time <= win1);
            tlW = tlAll(mW,:);
            if isempty(tlW)
                tPos = [win0; win1];
                pPos = [pos0; pos0];
                return;
            end

            pW = sign(double(tlW.QtyAfter));
            lastPos = pW(end);

            tPos = [win0; tlW.Time; win1];
            pPos = [pos0; pW; lastPos];
        end

        function force_trader_state(tr, pos)
            % Force trader.Pos to a given sign (-1/0/+1). Used for consistency.
            try
                if ismethod(tr,'sync_external_position')
                    tr.sync_external_position(sign(pos));
                    return;
                end
                if isprop(tr,'Pos')
                    tr.Pos = int8(sign(pos));
                end
                if sign(pos) == 0
                    if isprop(tr,'EntryPrice'), tr.EntryPrice = NaN; end
                    if isprop(tr,'EntryDate'), tr.EntryDate = NaT; end
                    if isprop(tr,'EntryIdx'),  tr.EntryIdx  = NaN; end
                end
            catch
                % do nothing
            end
        end
    end
end
