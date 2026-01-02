classdef ticker_trader < handle
    % ticker_trader (MACD-compatible, signature-preserving)
    %
    % Goals:
    %  - Keep existing public method signatures as much as possible.
    %  - Add MACD features via NEW properties only (optimizer can toggle on/off):
    %      1) Regime filter (entry gating) using MACD hist or MACD vs signal
    %      2) Exit assist (force exit when MACD flips against position)
    %      3) Position fraction scaling FIXED AT ENTRY (more realistic than daily rebal)
    %
    % Expectations:
    %  - ticker_data_manager.get_ctx_prev(t) returns legacy fields:
    %      smaWeek_prev, smaFast_prev, smaSlow_prev, atr_prev, longTermTrend_prev
    %    and (if MACD enabled in DM) macdLine_prev, macdSignal_prev, macdHist_prev
    %
    %  - backtest_engine calls: tr.step(tIdx, engine)
    %  - backtest_engine may call: tr.reset_for_run() or tr.reset_for_run(eq)
    %
    % NOTE: If you don't set MACD toggles, behavior matches the original MA/ATR rules.

    properties (SetAccess=private)
        DM ticker_data_manager

        % capital / equity
        Equity double = 0
        InitEquity double = 0

        % position state
        Pos int8 = 0           % -1/0/+1
        EntryPrice double = NaN
        EntryDate datetime = NaT

        % index bookkeeping
        EntryIdx double = NaN
        CooldownUntilIdx double = -Inf

        % position fraction (0..1), fixed at entry
        PositionFrac double = 1.0

        % cached MACD mode (avoid per-step string ops)
        MACDModeIsCross logical = false

        % history extrema while position is open
        HistMax double = -Inf  % max over {Open,Close} during position (LONG)
        HistMin double = Inf   % min over {Open,Close} during position (SHORT)

        % logs
        TradeLog table
        EqCurve timetable
        PosSeries timetable
        StopLog table
    end

    properties (Access=private)
        % --- Buffered logging (speed) ---
        CurveBufSize double = 30
        CurveBufN double = 0
        CurveBufDt datetime
        CurveBufEquity double
        CurveBufPos double

        TradeBufSize double = 10
        TradeBufN double = 0
        TradeBufTime datetime
        TradeBufAction string
        TradeBufPrice double
        TradeBufPosBefore double
        TradeBufPosAfter double
        TradeBufReason string
        TradeBufEqBefore double
        TradeBufEqAfter double
        TradeBufPosFrac double

        StopBufSize double = 10
        StopBufN double = 0
        StopBufTime datetime
        StopBufType string
        StopBufStopPx double
        StopBufHistRef double
        StopBufOpenPx double
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

        % ===== Market/regulatory constraint =====
        % Korean stock market short positions must be covered within 90 days.
        % (Enforced as calendar days since EntryDate.)
        EnforceShortMaxHold logical = false
        ShortMaxHoldDays double = Inf

        % ===== Engine authoritative fill logging =====
        % When enabled, trader will NOT log signal-based ENTER/EXIT.
        % Engine should call on_portfolio_fill() after actual execution.
        ExternalAccountingEnabled logical = false

        % ===== MACD additions (new) =====
        % Mode:
        %   "hist"  -> bull if macdHist_prev > 0
        %   "cross" -> bull if macdLine_prev > macdSignal_prev
        MACDSignalMode string = "hist";

        % Entry gating by MACD regime
        UseMACDRegimeFilter logical = false;

        % Exit assist: if MACD flips against position, allow signal-exit (still respects MinHoldDays)
        UseMACDExit logical = false;

        % Position fraction scaling AT ENTRY ONLY (PnL/costs scaled by PositionFrac)
        UseMACDSizeScaling logical = false;
        MACDSizeMin double = 0.25;
        MACDSizeMax double = 1.00;
        % Saturation threshold: |macdHist| >= MACDSizeAtrK * ATR  => PositionFrac ~= MACDSizeMax
        MACDSizeAtrK double = 0.50;

        % ===== Prev-close filter (new) =====
        % Use previous day's Close as additional confirmation for entry/exit.
        % Ref: "fast" (SMA20) or "week" (SMA5)
        UsePrevCloseFilter logical = false;
        PrevCloseFilterRef string = "fast";

        % logging switches (turn off during optimization for speed)
        LogCurves logical = true
        LogTrades logical = true
        LogStops  logical = true
    end

    methods
        function this = ticker_trader(dm, initEquity, enableShort)
            % Signature preserved: ticker_trader(dm, initEquity, enableShort)
            if nargin < 2 || isempty(initEquity), initEquity = 0; end
            if nargin < 3 || isempty(enableShort), enableShort = true; end

            this.DM = dm;
            this.Equity = initEquity;
            this.InitEquity = this.Equity;
            this.EnableShort = logical(enableShort);


            this.MACDModeIsCross = (lower(string(this.MACDSignalMode)) == "cross");
            this.TradeLog = table('Size',[0 9], ...
                'VariableTypes', ["datetime","string","double","double","double","string","double","double","double"], ...
                'VariableNames', ["Time","Action","Price","PosBefore","PosAfter","Reason","EquityBefore","EquityAfter","PosFrac"]);

            this.StopLog = table('Size',[0 5], ...
                'VariableTypes', ["datetime","string","double","double","double"], ...
                'VariableNames', ["Time","StopType","StopPx","HistRef","OpenPx"]);

            this.EqCurve = timetable(datetime.empty(0,1), double.empty(0,1), 'VariableNames', {'Equity'});
            this.PosSeries = timetable(datetime.empty(0,1), double.empty(0,1), 'VariableNames', {'Pos'});

            % init fixed-size log buffers
            this.init_log_buffers();
        end

        function set_logging(this, curvesOn, tradesOn, stopsOn)
            % Signature preserved
            if nargin < 2 || isempty(curvesOn), curvesOn = true; end
            if nargin < 3 || isempty(tradesOn), tradesOn = true; end
            if nargin < 4 || isempty(stopsOn),  stopsOn  = true; end
            this.LogCurves = logical(curvesOn);
            this.LogTrades = logical(tradesOn);
            this.LogStops  = logical(stopsOn);
        end

        function set_hparams(this, hp)
            % Signature preserved
            if isempty(hp), return; end
            if ~isstruct(hp)
                error("ticker_trader:set_hparams", "hp must be a struct.");
            end

            fn = fieldnames(hp);
            for k = 1:numel(fn)
                name = fn{k};
                if isprop(this, name)
                    this.(name) = hp.(name);
                end
            end

            % clamps
            this.ConfirmDays  = max(1, round(double(this.ConfirmDays)));
            this.MinHoldDays  = max(0, round(double(this.MinHoldDays)));
            this.CooldownDays = max(0, round(double(this.CooldownDays)));

            this.SpreadEnterPct = max(0, double(this.SpreadEnterPct));
            this.SpreadExitPct  = max(0, double(this.SpreadExitPct));
            this.AtrEnterK = max(0, double(this.AtrEnterK));
            this.AtrExitK  = max(0, double(this.AtrExitK));

            this.MACDSizeMin = max(0, min(1, double(this.MACDSizeMin)));
            this.MACDSizeMax = max(0, min(1, double(this.MACDSizeMax)));
            if this.MACDSizeMax < this.MACDSizeMin
                tmp = this.MACDSizeMin; this.MACDSizeMin = this.MACDSizeMax; this.MACDSizeMax = tmp;
            end
            if ~isfinite(this.MACDSizeAtrK) || this.MACDSizeAtrK <= 0
                this.MACDSizeAtrK = 0.50;
            end

            m = lower(string(this.MACDSignalMode));
            if m ~= "hist" && m ~= "cross"
                this.MACDSignalMode = "hist";
            else
                this.MACDSignalMode = m;
            end
            this.MACDModeIsCross = (this.MACDSignalMode == "cross");

            % Prev-close reference validation
            r = lower(string(this.PrevCloseFilterRef));
            if r ~= "fast" && r ~= "week"
                this.PrevCloseFilterRef = "fast";
            else
                this.PrevCloseFilterRef = r;
            end
        end

        function step(this, t, execModel)
            % Signature preserved: step(this, tIdx, execModel)
            if t < 3 || t > this.DM.length()-1
                return;
            end

            dt = this.DM.Date(t);
            O  = this.DM.Open(t);
            H  = this.DM.High(t);
            L  = this.DM.Low(t);
            C  = this.DM.Close(t);

            % 1) Borrow cost daily for shorts (scaled by PositionFrac)
            if this.Pos == -1
                this.Equity = this.Equity * (1 - this.PositionFrac * execModel.shortBorrowDaily());
            end

            % 2) Update history extrema
            if this.Pos ~= 0
                this.update_history_extrema(O, C);
            end

            % 2.5) Regulatory forced cover for short max holding period (e.g., KRX 90 days)
            % If enabled and a short has been held longer than ShortMaxHoldDays (calendar days),
            % force an exit at today's open and do NOT allow re-entry on the same bar.
            if this.EnforceShortMaxHold && this.Pos == -1 && ~isnat(this.EntryDate)
                heldCal = days(dt - this.EntryDate);
                if isfinite(this.ShortMaxHoldDays) && heldCal >= double(this.ShortMaxHoldDays)
                    this.exit_position(t, dt, O, execModel, "FORCED_COVER_MAXHOLD", NaN, O);
                    if dt >= execModel.StartDate && dt <= execModel.EndDate
                        this.append_curves(dt);
                    end
                    return;
                end
            end

            % 3) Stops intraday
            [stopHit, stopType, stopPx, histRef] = this.check_stop_intraday(O,H,L,C);
            if stopHit
                this.exit_position(t, dt, stopPx, execModel, "STOP:"+stopType, histRef, O);
                this.append_curves(dt);
                return;
            end

            % 4) Prev-day ctx
            ctx = this.DM.get_ctx_prev(t);
            if ~isfield(ctx,"valid") || ~ctx.valid
                this.append_curves(dt);
                return;
            end

            % 5) Signal decision (may use MACD)
            target = this.decide_target(t, ctx);

            % 6) Apply target at Open(t)
            if target ~= this.Pos
                if this.Pos ~= 0
                    this.exit_position(t, dt, O, execModel, "SignalExit", NaN, O);
                end
                if target ~= 0
                    this.enter_position(t, dt, O, target, execModel, "SignalEntry", ctx);
                end
            end

            % 7) Mark-to-market Open(t)->Open(t+1) scaled by PositionFrac
            O2 = this.DM.Open(t+1);
            if this.Pos ~= 0
                r = double(this.Pos) * (O2 / O - 1);
                if isfinite(r)
                    this.Equity = this.Equity * (1 + this.PositionFrac * r);
                end
            end

            if dt >= execModel.StartDate && dt <= execModel.EndDate
                this.append_curves(dt);
            end
        end

        function reset_for_run(this, initialEquity)
            % Signature preserved via nargin. backtest_engine may call with 0 or 1 arg.
            if nargin < 2 || isempty(initialEquity)
                initialEquity = this.InitEquity;
            else
                this.InitEquity = double(initialEquity);
            end

            this.Equity = initialEquity;

            this.Pos = int8(0);
            this.EntryPrice = NaN;
            this.EntryDate  = NaT;
            this.EntryIdx   = NaN;
            this.CooldownUntilIdx = -Inf;

            this.PositionFrac = 1.0;

            this.HistMax = -Inf;
            this.HistMin = Inf;

            this.TradeLog = this.TradeLog([],:);
            this.StopLog  = this.StopLog([],:);

            this.EqCurve   = timetable(datetime.empty(0,1), double.empty(0,1), 'VariableNames', {'Equity'});
            this.PosSeries = timetable(datetime.empty(0,1), double.empty(0,1), 'VariableNames', {'Pos'});

            % reset fixed-size log buffers
            this.init_log_buffers();
        end

        function allocate_equity(this, amount)
            if nargin < 2 || isempty(amount), return; end
            this.Equity = this.Equity + double(amount);
        end

        function amount = withdraw_equity(this, amount)
            if nargin < 2 || isempty(amount), amount = 0; end
            amount = min(double(amount), this.Equity);
            this.Equity = this.Equity - amount;
        end

        function reset_equity(this, amount)
            if nargin < 2 || isempty(amount), amount = 0; end
            this.Equity = double(amount);
        end

        function eq = get_equity(this)
            eq = this.Equity;
        end

        function TL = get_trade_log(this)
            % Getter for testing / reconciliation
            this.flush_log_buffers();
            TL = this.TradeLog;
        end

        function PS = get_pos_series(this)
            % Getter for testing / reconciliation (may be empty if LogCurves=false)
            this.flush_log_buffers();
            PS = this.PosSeries;
        end

        function flush_buffers(this)
            % Flush buffered logs to table/timetable (performance).
            this.flush_log_buffers();
        end

    end

methods
    function enable_external_accounting(this, tf)
        % Enable engine-authoritative accounting mode.
        % In this mode, trader should avoid logging signal-based trades.
        if nargin < 2
            tf = true;
        end
        this.ExternalAccountingEnabled = logical(tf);
    end

    function on_portfolio_fill(this, dt, action, price, posBefore, posAfter, reason)
        % Engine callback: record actual fills in TradeLog.
        % This keeps trader logs consistent with portfolio logs.
        if nargin < 7
            reason = "FILL";
        end
        if ~this.LogTrades
            return;
        end
        % Equity before/after are not known here (portfolio owns cash).
        eqB = NaN; eqA = NaN;
        try
            if isfinite(double(this.Equity))
                eqB = double(this.Equity);
                eqA = double(this.Equity);
            end
        catch
        end
        this.buf_add_trade(dt, string(action), double(price), double(posBefore), double(posAfter), string(reason), eqB, eqA, double(this.PositionFrac));
    end
end



    methods (Access=private)
        function target = decide_target(this, t, ctx)
            % Keep original MA/ATR logic, but add MACD gating/exit assist.
            % ctx fields are *_prev (legacy).

            % Cooldown block on new entries
            if this.Pos == 0 && t <= this.CooldownUntilIdx
                target = int8(0);
                return;
            end

            week = ctx.smaWeek_prev;
            fast = ctx.smaFast_prev;
            slow = ctx.smaSlow_prev;
            trend = ctx.longTermTrend_prev;
            atr = ctx.atr_prev;
            closePrev = NaN;
            if isfield(ctx, "close_prev"), closePrev = ctx.close_prev; end

            if any(~isfinite([week fast slow]))
                target = int8(0);
                return;
            end

            longStack  = (week > fast) && (fast > slow);
            shortStack = (slow > fast) && (fast > week);

            % separation gate week vs fast
            sepLong  = (week - fast);  % >0 helps long
            sepShort = (fast - week);  % >0 helps short
            den = max(abs(fast), realmin);

            if this.UseATRFilter && isfinite(atr) && atr > 0
                enterLongOK  = (sepLong  >= this.AtrEnterK * atr);
                exitLongOK   = (sepLong  <= this.AtrExitK  * atr);
                enterShortOK = (sepShort >= this.AtrEnterK * atr);
                exitShortOK  = (sepShort <= this.AtrExitK  * atr);
            else
                enterLongOK  = ((sepLong / den)  >= this.SpreadEnterPct);
                exitLongOK   = ((sepLong / den)  <= this.SpreadExitPct);
                enterShortOK = ((sepShort / den) >= this.SpreadEnterPct);
                exitShortOK  = ((sepShort / den) <= this.SpreadExitPct);
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

            % MACD regime state (optional)
            [macdBull, macdBear] = this.macd_state(ctx);
            if this.UseMACDRegimeFilter
                macdLongOK  = macdBull;
                macdShortOK = macdBear;
            else
                macdLongOK  = true;
                macdShortOK = true;
            end

            % confirmation (N consecutive days)
            confN = max(1, round(double(this.ConfirmDays)));
            longConf  = this.check_confirm_long(t-1, confN);
            shortConf = this.check_confirm_short(t-1, confN);

            % Prev-close gating (optional)
            prevCloseLongOK = true;
            prevCloseShortOK = true;
            if this.UsePrevCloseFilter && isfinite(closePrev)
                if this.PrevCloseFilterRef == "week"
                    refMA = week;
                else
                    refMA = fast;
                end
                if isfinite(refMA)
                    prevCloseLongOK  = (closePrev >= refMA);
                    prevCloseShortOK = (closePrev <= refMA);
                end
            end

            longEntry  = longStack  && enterLongOK  && trendLongOK  && macdLongOK  && longConf  && prevCloseLongOK;
            shortEntry = shortStack && enterShortOK && trendShortOK && macdShortOK && shortConf && this.EnableShort && prevCloseShortOK;

            % exits
            longExitCross  = (fast > week);
            shortExitCross = (week > fast);

            held = 0;
            if this.Pos ~= 0 && isfinite(this.EntryIdx)
                held = t - this.EntryIdx;
            end
            canExit = (held >= max(0, round(double(this.MinHoldDays))));

            macdExitLong = false;
            macdExitShort = false;
            if this.UseMACDExit && canExit
                macdExitLong  = macdBear;
                macdExitShort = macdBull;
            end

            prevCloseExitLong = false;
            prevCloseExitShort = false;
            if this.UsePrevCloseFilter && canExit && isfinite(closePrev)
                if this.PrevCloseFilterRef == "week"
                    refMA = week;
                else
                    refMA = fast;
                end
                if isfinite(refMA)
                    prevCloseExitLong  = (closePrev < refMA);
                    prevCloseExitShort = (closePrev > refMA);
                end
            end

            if this.Pos == 0
                if longEntry
                    target = int8(1);
                elseif shortEntry
                    target = int8(-1);
                else
                    target = int8(0);
                end
            elseif this.Pos == 1
                if canExit && (longExitCross || exitLongOK || macdExitLong || prevCloseExitLong)
                    target = int8(0);
                else
                    target = int8(1);
                end
            else % -1
                if canExit && (shortExitCross || exitShortOK || macdExitShort || prevCloseExitShort)
                    target = int8(0);
                else
                    target = int8(-1);
                end
            end
        end

        function [bull, bear] = macd_state(this, ctx)
            bull = false; bear = false;
            m = lower(string(this.MACDSignalMode));

            if m == "cross"
                ml = ctx.macdLine_prev;
                ms = ctx.macdSignal_prev;
                if isfinite(ml) && isfinite(ms)
                    bull = (ml > ms);
                    bear = (ml < ms);
                end
            else
                mh = ctx.macdHist_prev;
                if isfinite(mh)
                    bull = (mh > 0);
                    bear = (mh < 0);
                end
            end
        end

        function ok = check_confirm_long(this, p, confN)
            dm = this.DM;
            if p - confN + 1 < 1
                ok = false; return;
            end
            ok = true;
            for i=(p-confN+1):p
                w = dm.smaWeek(i); f = dm.smaFast(i); s = dm.smaSlow(i);
                if any(~isfinite([w f s])) || ~(w > f && f > s)
                    ok = false; return;
                end
            end
        end

        function ok = check_confirm_short(this, p, confN)
            dm = this.DM;
            if p - confN + 1 < 1
                ok = false; return;
            end
            ok = true;
            for i=(p-confN+1):p
                w = dm.smaWeek(i); f = dm.smaFast(i); s = dm.smaSlow(i);
                if any(~isfinite([w f s])) || ~(s > f && f > w)
                    ok = false; return;
                end
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
            else
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

        function enter_position(this, tIdx, dt, px, newPos, execModel, reason, ctx)
            eqBefore = this.Equity;
            posBefore = this.Pos;

            % PositionFrac fixed at entry
            this.PositionFrac = this.compute_entry_position_frac(ctx);

            fee = execModel.entryFee(double(newPos), dt);
            this.Equity = this.Equity * (1 - fee * this.PositionFrac);

            this.Pos = int8(newPos);
            this.EntryPrice = px;
            this.EntryDate = dt;
            this.EntryIdx = tIdx;

            if this.Pos == 1
                this.HistMax = px; this.HistMin = Inf;
            else
                this.HistMin = px; this.HistMax = -Inf;
            end

            if this.LogTrades && ~this.ExternalAccountingEnabled
                this.buf_add_trade(dt, "ENTER", px, double(posBefore), double(this.Pos), string(reason), eqBefore, this.Equity, this.PositionFrac);
            end
        end

        function frac = compute_entry_position_frac(this, ctx)
            if ~this.UseMACDSizeScaling
                frac = 1.0;
                return;
            end

            mh = ctx.macdHist_prev;
            atr = ctx.atr_prev;

            if ~isfinite(mh)
                frac = 1.0; return;
            end

            if isfinite(atr) && atr > 0
                strength = abs(mh) / atr;   % dimensionless
            else
                ml = ctx.macdLine_prev;
                ms = ctx.macdSignal_prev;
                den = max([abs(ml), abs(ms), realmin]);
                strength = abs(mh) / den;
            end

            k = max(realmin, this.MACDSizeAtrK);
            x = min(1.0, strength / k);
            frac = this.MACDSizeMin + x * (this.MACDSizeMax - this.MACDSizeMin);
            frac = max(0.0, min(1.0, frac));
        end

        function exit_position(this, tIdx, dt, px, execModel, reason, histRef, openPx)
            eqBefore = this.Equity;
            posBefore = this.Pos;

            fee = execModel.exitFee(double(this.Pos), dt);
            this.Equity = this.Equity * (1 - fee * this.PositionFrac);

            if startsWith(string(reason), "STOP:")
                if this.LogStops
                    this.buf_add_stop(dt, string(reason), px, histRef, openPx);
                end
            end

            this.Pos = int8(0);
            this.EntryPrice = NaN;
            this.EntryDate = NaT;
            this.EntryIdx = NaN;

            this.PositionFrac = 1.0;

            this.HistMax = -Inf;
            this.HistMin = Inf;

            this.CooldownUntilIdx = tIdx + max(0, round(double(this.CooldownDays)));

            if this.LogTrades && ~this.ExternalAccountingEnabled
                this.buf_add_trade(dt, "EXIT", px, double(posBefore), double(this.Pos), string(reason), eqBefore, this.Equity, this.PositionFrac);
            end
        end

        function append_curves(this, dt)
            if ~this.LogCurves
                return;
            end
            this.buf_add_curve(dt, this.Equity, double(this.Pos));
        end

        % ===== External accounting support (engine authoritative) =====
        % 포트폴리오 엔진이 실제 체결 결과(보유 포지션 부호)를 알려주면,
        % trader 내부 상태(Pos, entry bookkeeping)를 강제로 동기화합니다.
        %
        % 사용처: 주문 거부/다운사이징 등으로 trader의 '희망 포지션'과
        % 실제 포트폴리오 보유가 불일치할 때, 다음 스텝의 로직 꼬임을 방지.
        function sync_external_position(this, posSign)
            posSign = sign(double(posSign));
            this.Pos = int8(posSign);
            if posSign == 0
                this.EntryPrice = NaN;
                this.EntryDate  = NaT;
                this.EntryIdx   = NaN;
                this.HistMax = -Inf;
                this.HistMin = Inf;
            end
        end
    end
    methods
        function R = report(this)
            % Return a lightweight snapshot of trader state and logs.
            this.flush_log_buffers();
            R = struct();
            try
                if isprop(this, 'DM') && ~isempty(this.DM) && isprop(this.DM, 'Ticker')
                    R.Symbol = string(this.DM.Ticker);
                end
            catch
            end
            R.Pos = double(this.Pos);
            R.EntryPrice = double(this.EntryPrice);
            R.EntryDate = this.EntryDate;
            R.Equity = double(this.Equity);
            R.InitEquity = double(this.InitEquity);
            R.PositionFrac = double(this.PositionFrac);
            R.TradeLog = this.TradeLog;
            R.StopLog = this.StopLog;
            R.EqCurve = this.EqCurve;
            R.PosSeries = this.PosSeries;
        end
    end

    methods (Access=private)
        function init_log_buffers(this)
            % Preallocate fixed-size caches.
            nC = max(1, round(double(this.CurveBufSize)));
            this.CurveBufN = 0;
            % NOTE: datetime.empty(m,n) requires at least one dimension be 0.
            % For fixed-size buffers we preallocate with NaT.
            this.CurveBufDt = NaT(nC,1);
            this.CurveBufEquity = nan(nC,1);
            this.CurveBufPos = nan(nC,1);

            nT = max(1, round(double(this.TradeBufSize)));
            this.TradeBufN = 0;
            % Fixed-size buffers: use NaT preallocation (not datetime.empty).
            this.TradeBufTime = NaT(nT,1);
            this.TradeBufAction = strings(nT,1);
            this.TradeBufPrice = nan(nT,1);
            this.TradeBufPosBefore = nan(nT,1);
            this.TradeBufPosAfter = nan(nT,1);
            this.TradeBufReason = strings(nT,1);
            this.TradeBufEqBefore = nan(nT,1);
            this.TradeBufEqAfter = nan(nT,1);
            this.TradeBufPosFrac = nan(nT,1);

            nS = max(1, round(double(this.StopBufSize)));
            this.StopBufN = 0;
            % Fixed-size buffers: use NaT preallocation (not datetime.empty).
            this.StopBufTime = NaT(nS,1);
            this.StopBufType = strings(nS,1);
            this.StopBufStopPx = nan(nS,1);
            this.StopBufHistRef = nan(nS,1);
            this.StopBufOpenPx = nan(nS,1);
        end

        function flush_log_buffers(this)
            % Flush all caches to table/timetable.
            this.flush_trade_buf();
            this.flush_stop_buf();
            this.flush_curve_buf();
        end

        function buf_add_curve(this, dt, equity, pos)
            if ~this.LogCurves
                return;
            end
            this.CurveBufN = this.CurveBufN + 1;
            k = this.CurveBufN;
            if k > numel(this.CurveBufEquity)
                this.flush_curve_buf();
                this.CurveBufN = 1;
                k = 1;
            end
            this.CurveBufDt(k,1) = dt;
            this.CurveBufEquity(k,1) = double(equity);
            this.CurveBufPos(k,1) = double(pos);
            if this.CurveBufN >= this.CurveBufSize
                this.flush_curve_buf();
            end
        end

        function buf_add_trade(this, dt, action, price, posBefore, posAfter, reason, eqBefore, eqAfter, posFrac)
            if ~this.LogTrades
                return;
            end
            this.TradeBufN = this.TradeBufN + 1;
            k = this.TradeBufN;
            if k > numel(this.TradeBufPrice)
                this.flush_trade_buf();
                this.TradeBufN = 1;
                k = 1;
            end
            this.TradeBufTime(k,1) = dt;
            this.TradeBufAction(k,1) = string(action);
            this.TradeBufPrice(k,1) = double(price);
            this.TradeBufPosBefore(k,1) = double(posBefore);
            this.TradeBufPosAfter(k,1) = double(posAfter);
            this.TradeBufReason(k,1) = string(reason);
            this.TradeBufEqBefore(k,1) = double(eqBefore);
            this.TradeBufEqAfter(k,1) = double(eqAfter);
            this.TradeBufPosFrac(k,1) = double(posFrac);
            if this.TradeBufN >= this.TradeBufSize
                this.flush_trade_buf();
            end
        end

        function buf_add_stop(this, dt, stopType, stopPx, histRef, openPx)
            if ~this.LogStops
                return;
            end
            this.StopBufN = this.StopBufN + 1;
            k = this.StopBufN;
            if k > numel(this.StopBufStopPx)
                this.flush_stop_buf();
                this.StopBufN = 1;
                k = 1;
            end
            this.StopBufTime(k,1) = dt;
            this.StopBufType(k,1) = string(stopType);
            this.StopBufStopPx(k,1) = double(stopPx);
            this.StopBufHistRef(k,1) = double(histRef);
            this.StopBufOpenPx(k,1) = double(openPx);
            if this.StopBufN >= this.StopBufSize
                this.flush_stop_buf();
            end
        end

        function flush_curve_buf(this)
            n = this.CurveBufN;
            if n <= 0
                return;
            end
            dts = this.CurveBufDt(1:n,1);
            eqs = this.CurveBufEquity(1:n,1);
            ps  = this.CurveBufPos(1:n,1);
            this.EqCurve = [this.EqCurve; timetable(dts, eqs, 'VariableNames', {'Equity'})]; %#ok<AGROW>
            this.PosSeries = [this.PosSeries; timetable(dts, ps, 'VariableNames', {'Pos'})]; %#ok<AGROW>
            this.CurveBufN = 0;
        end

        function flush_trade_buf(this)
            n = this.TradeBufN;
            if n <= 0
                return;
            end
            T = table(this.TradeBufTime(1:n,1), this.TradeBufAction(1:n,1), this.TradeBufPrice(1:n,1), ...
                this.TradeBufPosBefore(1:n,1), this.TradeBufPosAfter(1:n,1), this.TradeBufReason(1:n,1), ...
                this.TradeBufEqBefore(1:n,1), this.TradeBufEqAfter(1:n,1), this.TradeBufPosFrac(1:n,1), ...
                'VariableNames', ["Time","Action","Price","PosBefore","PosAfter","Reason","EquityBefore","EquityAfter","PosFrac"]);
            this.TradeLog = [this.TradeLog; T]; %#ok<AGROW>
            this.TradeBufN = 0;
        end

        function flush_stop_buf(this)
            n = this.StopBufN;
            if n <= 0
                return;
            end
            S = table(this.StopBufTime(1:n,1), this.StopBufType(1:n,1), this.StopBufStopPx(1:n,1), ...
                this.StopBufHistRef(1:n,1), this.StopBufOpenPx(1:n,1), ...
                'VariableNames', ["Time","StopType","StopPx","HistRef","OpenPx"]);
            this.StopLog = [this.StopLog; S]; %#ok<AGROW>
            this.StopBufN = 0;
        end
    end

end
