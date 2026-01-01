classdef ticker_trader < handle
    % ticker_trader
    % - Holds one ticker_data_manager
    % - Decides LONG/SHORT/FLAT based on MA stacking + filters
    % - Tracks position history extrema (max/min over open/close)
    % - Executes stop exits (intraday via OHLC reach)
    % - Manages equity (cash allocated to this trader)

    properties (SetAccess=private)
        DM ticker_data_manager

        % capital / equity
        Equity double = 0

        % position state
        Pos int8 = 0           % -1/0/+1
        EntryPrice double = NaN
        EntryDate datetime = NaT

        % index bookkeeping (for MinHold/Cooldown)
        EntryIdx double = NaN
        CooldownUntilIdx double = -Inf

        % history extrema while position is open
        HistMax double = -Inf  % max over {Open,Close} during position (LONG)
        HistMin double = Inf   % min over {Open,Close} during position (SHORT)

        % logs
        TradeLog table
        EqCurve timetable
        PosSeries timetable
        StopLog table
    end

    properties
        % ===== Hyperparameters (optimizer expects these) =====
        % Separation filter (SMA5 vs SMA20) + hysteresis
        SpreadEnterPct double = 0.0030   % entry threshold (pct)
        SpreadExitPct  double = 0.0010   % exit threshold (pct)

        % ATR-normalized separation (recommended)
        UseATRFilter logical = true
        AtrEnterK double = 0.35
        AtrExitK  double = 0.10

        % Anti-whipsaw
        ConfirmDays  double = 2      % require N consecutive days satisfying entry condition
        MinHoldDays  double = 3      % minimum holding days before signal-exit allowed
        CooldownDays double = 0      % wait N days after exit before new entry

        % Trend filter options
        UseLongTrendFilter  logical = true   % require longTermTrend_prev==+1 for long entry
        UseShortTrendFilter logical = false  % if true, require longTermTrend_prev==-1 for short entry

        % stop params
        LongDailyStop double = 0.05
        LongTrailStop double = 0.10

        ShortDailyStop double = 0.03
        ShortTrailStop double = 0.10

        EnableShort logical = true

        % logging switches (turn off during optimization for speed)
        LogCurves logical = true
        LogTrades logical = true
        LogStops  logical = true
    end

    methods
        function this = ticker_trader(dm, initEquity, enableShort)
            arguments
                dm (1,1) ticker_data_manager
                initEquity (1,1) double {mustBeNonnegative} = 0
                enableShort (1,1) logical = true
            end

            this.DM = dm;
            this.Equity = initEquity;
            this.EnableShort = enableShort;

            this.TradeLog = table('Size',[0 8], ...
                'VariableTypes', ["datetime","string","double","double","double","string","double","double"], ...
                'VariableNames', ["Time","Action","Price","PosBefore","PosAfter","Reason","EquityBefore","EquityAfter"]);

            this.StopLog = table('Size',[0 5], ...
                'VariableTypes', ["datetime","string","double","double","double"], ...
                'VariableNames', ["Time","StopType","StopPx","HistRef","OpenPx"]);

            this.EqCurve = timetable(datetime.empty(0,1), double.empty(0,1), 'VariableNames', {'Equity'});
            this.PosSeries = timetable(datetime.empty(0,1), double.empty(0,1), 'VariableNames', {'Pos'});
        end

        function set_logging(this, curvesOn, tradesOn, stopsOn)
            if nargin < 2 || isempty(curvesOn), curvesOn = true; end
            if nargin < 3 || isempty(tradesOn), tradesOn = true; end
            if nargin < 4 || isempty(stopsOn),  stopsOn  = true; end
            this.LogCurves = logical(curvesOn);
            this.LogTrades = logical(tradesOn);
            this.LogStops  = logical(stopsOn);
        end

        function set_hparams(this, hp)
            % Apply hyperparameter struct from optimizer script
            if isempty(hp), return; end
            if ~isstruct(hp)
                error("ticker_trader:set_hparams", "hp must be a struct.");
            end

            fn = fieldnames(hp);
            for k = 1:numel(fn)
                name = fn{k};
                if isprop(this, name)
                    this.(name) = hp.(name);
                else
                    % ignore unknown fields (optimizer may carry extra keys)
                    % warning("ticker_trader:set_hparams", "Unknown field '%s' ignored.", name);
                end
            end

            % Light sanity clamps (avoid negative/NaN breaking logic)
            this.ConfirmDays  = max(1, round(double(this.ConfirmDays)));
            this.MinHoldDays  = max(0, round(double(this.MinHoldDays)));
            this.CooldownDays = max(0, round(double(this.CooldownDays)));

            if ~isfinite(this.SpreadEnterPct) || this.SpreadEnterPct < 0, this.SpreadEnterPct = 0; end
            if ~isfinite(this.SpreadExitPct)  || this.SpreadExitPct  < 0, this.SpreadExitPct  = 0; end
            if ~isfinite(this.AtrEnterK) || this.AtrEnterK < 0, this.AtrEnterK = 0; end
            if ~isfinite(this.AtrExitK)  || this.AtrExitK  < 0, this.AtrExitK  = 0; end
        end

        function step(this, t, execModel)
            % one-day update at index t (execute at Open(t))
            if t < 3 || t > this.DM.length()-1
                return;
            end

            dt = this.DM.Date(t);
            O  = this.DM.Open(t);
            H  = this.DM.High(t);
            L  = this.DM.Low(t);
            C  = this.DM.Close(t);

            eqBefore = this.Equity;
            posBefore = this.Pos;

            % 1) Borrow cost daily (apply at start of day for shorts)
            if this.Pos == -1
                this.Equity = this.Equity * (1 - execModel.shortBorrowDaily());
            end

            % 2) Update history extrema for active position
            if this.Pos ~= 0
                this.update_history_extrema(O, C);
            end

            % 3) Check stops intraday
            [stopHit, stopType, stopPx, histRef] = this.check_stop_intraday(O,H,L,C);
            if stopHit
                this.exit_position(t, dt, stopPx, execModel, "STOP:"+stopType, histRef, O);
                this.append_curves(dt);
                return;
            end

            % 4) Decide target position using prev-day ctx (execute at Open(t))
            ctx = this.DM.get_ctx_prev(t);
            if ~ctx.valid
                this.append_curves(dt);
                return;
            end

            target = this.decide_target(t);

            % 5) Execute rebalance at Open(t)
            if target ~= this.Pos
                if this.Pos ~= 0
                    this.exit_position(t, dt, O, execModel, "SignalExit", NaN, O);
                end
                if target ~= 0
                    this.enter_position(t, dt, O, target, execModel, "SignalEntry");
                end
            end

            % 6) Mark-to-market from Open(t)->Open(t+1)
            O2 = this.DM.Open(t+1);
            if this.Pos ~= 0
                r = double(this.Pos) * (O2 / O - 1);
                if isfinite(r)
                    this.Equity = this.Equity * (1 + r);
                end
            end

            if dt >= execModel.StartDate && dt <= execModel.EndDate
                this.append_curves(dt);
            end

            %#ok<NASGU>
            eqAfter = this.Equity; posAfter = this.Pos; %#ok<NASGU>
        end

        function allocate_equity(this, amount)
            arguments
                this
                amount (1,1) double {mustBeNonnegative}
            end
            this.Equity = this.Equity + amount;
        end

        function amount = withdraw_equity(this, amount)
            arguments
                this
                amount (1,1) double {mustBeNonnegative}
            end
            amount = min(amount, this.Equity);
            this.Equity = this.Equity - amount;
        end

        function reset_equity(this, amount)
            arguments
                this
                amount (1,1) double {mustBeNonnegative}
            end
            this.Equity = amount;
        end

        function eq = get_equity(this)
            eq = this.Equity;
        end

        function reset_for_run(this, initialEquity)
            arguments
                this
                initialEquity (1,1) double {mustBeNonnegative} = this.Equity
            end

            % ----- account/state -----
            this.Equity = initialEquity;

            this.Pos = int8(0);
            this.EntryPrice = NaN;
            this.EntryDate = NaT;
            this.EntryIdx = NaN;
            this.CooldownUntilIdx = -Inf;

            this.HistMax = -Inf;
            this.HistMin = Inf;

            % ----- logs -----
            this.TradeLog = this.TradeLog([],:); % keep schema, clear rows
            this.StopLog  = this.StopLog([],:);

            % ----- curves -----
            this.EqCurve   = timetable(datetime.empty(0,1), double.empty(0,1), 'VariableNames', {'Equity'});
            this.PosSeries = timetable(datetime.empty(0,1), double.empty(0,1), 'VariableNames', {'Pos'});
        end
    end

    methods (Access=private)
        function target = decide_target(this, t)
            % Use previous-day indicators for decision.
            dm = this.DM;
            p = t - 1;

            week  = dm.smaWeek(p);
            fast  = dm.smaFast(p);
            slow  = dm.smaSlow(p);
            trend = dm.longTermTrend(p);
            atr   = dm.atr(p);

            if any(~isfinite([week fast slow]))
                target = int8(0);
                return;
            end

            % Cooldown: block new entries
            if this.Pos == 0 && t <= this.CooldownUntilIdx
                target = int8(0);
                return;
            end

            % stacking
            longStack  = (week > fast) && (fast > slow);
            shortStack = (slow > fast) && (fast > week);

            % separation checks (week vs fast)
            sepLong = (week - fast); % >0 helps long
            sepShort = (fast - week); % >0 helps short
            fastDen = max(abs(fast), realmin);

            if this.UseATRFilter && isfinite(atr) && atr > 0
                enterLongOK  = (sepLong  >= this.AtrEnterK * atr);
                exitLongOK   = (sepLong  <= this.AtrExitK  * atr);
                enterShortOK = (sepShort >= this.AtrEnterK * atr);
                exitShortOK  = (sepShort <= this.AtrExitK  * atr);
            else
                enterLongOK  = ((sepLong / fastDen)  >= this.SpreadEnterPct);
                exitLongOK   = ((sepLong / fastDen)  <= this.SpreadExitPct);
                enterShortOK = ((sepShort / fastDen) >= this.SpreadEnterPct);
                exitShortOK  = ((sepShort / fastDen) <= this.SpreadExitPct);
            end

            % trend filters
            if this.UseLongTrendFilter
                trendLongOK = (trend == 1);
            else
                trendLongOK = true;
            end
            if this.UseShortTrendFilter
                trendShortOK = (trend == -1);
            else
                trendShortOK = true;
            end

            % confirmation for entries (N consecutive days on prev-close basis)
            confN = max(1, round(double(this.ConfirmDays)));
            entryLongConf  = this.check_confirm_long(p, confN);
            entryShortConf = this.check_confirm_short(p, confN);

            longEntry = longStack && enterLongOK && trendLongOK && entryLongConf;
            shortEntry = this.EnableShort && shortStack && enterShortOK && trendShortOK && entryShortConf;

            % exits (signal-based) + MinHoldDays gate
            held = 0;
            if this.Pos ~= 0 && isfinite(this.EntryIdx)
                held = t - this.EntryIdx;
            end
            canExitBySignal = (held >= max(0, round(double(this.MinHoldDays))));

            longExitCross  = (fast > week);
            shortExitCross = (week > fast);

            if this.Pos == 0
                if longEntry
                    target = int8(1);
                elseif shortEntry
                    target = int8(-1);
                else
                    target = int8(0);
                end
            elseif this.Pos == 1
                if canExitBySignal && (longExitCross || exitLongOK)
                    target = int8(0);
                else
                    target = int8(1);
                end
            else % -1
                if canExitBySignal && (shortExitCross || exitShortOK)
                    target = int8(0);
                else
                    target = int8(-1);
                end
            end
        end

        function ok = check_confirm_long(this, p, confN)
            dm = this.DM;
            if p - confN + 1 < 1
                ok = false; return;
            end
            ok = true;
            for i = (p-confN+1):p
                w = dm.smaWeek(i); f = dm.smaFast(i); s = dm.smaSlow(i);
                if any(~isfinite([w f s])), ok = false; return; end
                if ~(w > f && f > s), ok = false; return; end
            end
        end

        function ok = check_confirm_short(this, p, confN)
            dm = this.DM;
            if p - confN + 1 < 1
                ok = false; return;
            end
            ok = true;
            for i = (p-confN+1):p
                w = dm.smaWeek(i); f = dm.smaFast(i); s = dm.smaSlow(i);
                if any(~isfinite([w f s])), ok = false; return; end
                if ~(s > f && f > w), ok = false; return; end
            end
        end

        function update_history_extrema(this, O, C)
            ocMax = max(O, C);
            ocMin = min(O, C);
            if this.Pos == 1
                this.HistMax = max(this.HistMax, ocMax);
            elseif this.Pos == -1
                this.HistMin = min(this.HistMin, ocMin);
            end
        end

        function [hit, typ, stopPx, histRef] = check_stop_intraday(this, O,H,L,C)
            %#ok<INUSD>
            hit=false; typ=""; stopPx=NaN; histRef=NaN;

            if this.Pos == 0
                return;
            end

            if this.Pos == 1
                dailyPx = O * (1 - this.LongDailyStop);
                trailPx = this.HistMax * (1 - this.LongTrailStop);
                px = max(dailyPx, trailPx);

                if L <= px
                    hit=true; stopPx=px;
                    if dailyPx >= trailPx
                        typ="LongDaily"; histRef=dailyPx;
                    else
                        typ="LongTrail"; histRef=this.HistMax;
                    end
                end

            else % short
                dailyPx = O * (1 + this.ShortDailyStop);
                trailPx = this.HistMin * (1 + this.ShortTrailStop);
                px = min(dailyPx, trailPx);

                if H >= px
                    hit=true; stopPx=px;
                    if dailyPx <= trailPx
                        typ="ShortDaily"; histRef=dailyPx;
                    else
                        typ="ShortTrail"; histRef=this.HistMin;
                    end
                end
            end
        end

        function enter_position(this, tIdx, dt, px, newPos, execModel, reason)
            eqBefore = this.Equity;
            posBefore = this.Pos;

            fee = execModel.entryFee(double(newPos), dt);
            this.Equity = this.Equity * (1 - fee);

            this.Pos = int8(newPos);
            this.EntryPrice = px;
            this.EntryDate = dt;
            this.EntryIdx = tIdx;

            % init extrema
            if this.Pos == 1
                this.HistMax = px;
                this.HistMin = Inf;
            else
                this.HistMin = px;
                this.HistMax = -Inf;
            end

            if this.LogTrades
                this.TradeLog = [this.TradeLog; {dt,"ENTER",px,double(posBefore),double(this.Pos),string(reason),eqBefore,this.Equity}]; %#ok<AGROW>
            end
        end

        function exit_position(this, tIdx, dt, px, execModel, reason, histRef, openPx)
            eqBefore = this.Equity;
            posBefore = this.Pos;

            fee = execModel.exitFee(double(this.Pos), dt);
            this.Equity = this.Equity * (1 - fee);

            if startsWith(string(reason), "STOP:")
                if this.LogStops
                    this.StopLog = [this.StopLog; {dt, string(reason), px, histRef, openPx}]; %#ok<AGROW>
                end
            end

            % cooldown starts after exit
            this.CooldownUntilIdx = tIdx + max(0, round(double(this.CooldownDays)));

            this.Pos = int8(0);
            this.EntryPrice = NaN;
            this.EntryDate = NaT;
            this.EntryIdx = NaN;
            this.HistMax = -Inf;
            this.HistMin = Inf;

            if this.LogTrades
                this.TradeLog = [this.TradeLog; {dt,"EXIT",px,double(posBefore),double(this.Pos),string(reason),eqBefore,this.Equity}]; %#ok<AGROW>
            end
        end

        function append_curves(this, dt)
            if ~this.LogCurves
                return;
            end
            this.EqCurve = [this.EqCurve; timetable(dt, this.Equity, 'VariableNames', {'Equity'})]; %#ok<AGROW>
            this.PosSeries = [this.PosSeries; timetable(dt, double(this.Pos), 'VariableNames', {'Pos'})]; %#ok<AGROW>
        end
    end
end
