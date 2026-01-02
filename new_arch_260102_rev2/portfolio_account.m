classdef portfolio_account < handle
    % portfolio_account
    % ---------------------------------------------------------------------
    % Portfolio-level accounting container.
    %
    % Key responsibilities
    %   - Track Cash / Positions / ReservedMargin
    %   - Apply Fees / Taxes / Borrow cost
    %   - Record execution logs (TradeLog, BorrowLog) and EquityCurve
    %   - Provide summary reports (ALL or per TraderId)
    %
    % Performance note (important):
    %   Appending rows to table/timetable inside a long backtest loop is slow.
    %   This class buffers new rows in fixed-size arrays and flushes them to
    %   table/timetable only when buffers fill up or when data is requested.
    %
    % Compatibility note:
    %   - TradeLog / BorrowLog / EquityCurve are exposed as Dependent
    %     properties; getters auto-flush buffers so outside reads see the
    %     complete up-to-date logs.
    %   - RowTimes dimension name of EquityCurve is set to 'dt' so that code
    %     can access EC.dt (row times) if desired.

    properties
        InitialCapital (1,1) double = 0.0
        Cash           (1,1) double = 0.0

        ReservedMargin (1,1) double = 0.0

        % Maps
        Positions   containers.Map   % key: char(symbol), value: position
        LastPrices  containers.Map   % key: char(symbol), value: double(price)

        % Totals (portfolio-wide)
        FeesPaid   (1,1) double = 0.0
        TaxesPaid  (1,1) double = 0.0
        BorrowPaid (1,1) double = 0.0
    end

    properties (Dependent)
        TradeLog    table
        BorrowLog   table
        EquityCurve timetable
    end

    properties
        % Buffer sizes (tunable)
        EquityBufSize (1,1) double = 30   % daily-ish, so 30 is reasonable
        TradeBufSize  (1,1) double = 10   % event-driven, smaller is fine
        BorrowBufSize (1,1) double = 30   % can be daily when short is held
    end

    properties (Access=private)
        % Underlying storages (only appended on flush)
        TradeLog_    table
        BorrowLog_   table
        EquityCurve_ timetable

        % --- Equity buffer ---
        EqBufN   (1,1) double = 0
        EqBufDt        datetime
        EqBufEquity    double
        EqBufCash      double
        EqBufResM      double
        EqBufGrossExp  double
        EqBufNetExp    double

        % --- Trade buffer ---
        TrBufN   (1,1) double = 0
        TrBufTime     datetime
        TrBufSymbol   string
        TrBufTraderId string
        TrBufAction   string
        TrBufSide     string
        TrBufQtyDelta double
        TrBufQtyAfter double
        TrBufPrice    double
        TrBufNotional double
        TrBufFee      double
        TrBufTax      double
        TrBufReason   string

        % --- Borrow buffer ---
        BrBufN   (1,1) double = 0
        BrBufTime     datetime
        BrBufSymbol   string
        BrBufTraderId string
        BrBufCost     double
    end

    methods
        function this = portfolio_account(initialCapital)
            if nargin < 1 || isempty(initialCapital)
                initialCapital = 0;
            end
            this.InitialCapital = double(initialCapital);
            this.Cash = this.InitialCapital;

            this.Positions  = containers.Map('KeyType','char','ValueType','any');
            this.LastPrices = containers.Map('KeyType','char','ValueType','double');

            % Underlying logs (flushed storage)
            this.TradeLog_ = table('Size',[0 12], ...
                'VariableTypes', ["datetime","string","string","string","string", ...
                                  "double","double","double","double","double","double","string"], ...
                'VariableNames', ["Time","Symbol","TraderId","Action","Side", ...
                                  "QtyDelta","QtyAfter","Price","Notional","Fee","Tax","Reason"]);

            this.BorrowLog_ = table('Size',[0 4], ...
                'VariableTypes', ["datetime","string","string","double"], ...
                'VariableNames', ["Time","Symbol","TraderId","Cost"]);

            this.EquityCurve_ = timetable( ...
                datetime.empty(0,1), ... % row times
                double.empty(0,1), ...   % Equity
                double.empty(0,1), ...   % Cash
                double.empty(0,1), ...   % ReservedMargin
                double.empty(0,1), ...   % GrossExposure
                double.empty(0,1), ...   % NetExposure
                'VariableNames', {'Equity','Cash','ReservedMargin','GrossExposure','NetExposure'});
            % Dimension name so code can access EC.dt (RowTimes) if desired
            this.EquityCurve_.Properties.DimensionNames{1} = 'dt';

            % Initialize buffers
            this.init_buffers();
        end

        function init_buffers(this)
            % Equity buffer
            nE = max(1, round(this.EquityBufSize));
            this.EqBufN = 0;
            this.EqBufDt       = NaT(nE,1);
            this.EqBufEquity   = nan(nE,1);
            this.EqBufCash     = nan(nE,1);
            this.EqBufResM     = nan(nE,1);
            this.EqBufGrossExp = nan(nE,1);
            this.EqBufNetExp   = nan(nE,1);

            % Trade buffer
            nT = max(1, round(this.TradeBufSize));
            this.TrBufN = 0;
            this.TrBufTime     = NaT(nT,1);
            this.TrBufSymbol   = strings(nT,1);
            this.TrBufTraderId = strings(nT,1);
            this.TrBufAction   = strings(nT,1);
            this.TrBufSide     = strings(nT,1);
            this.TrBufQtyDelta = nan(nT,1);
            this.TrBufQtyAfter = nan(nT,1);
            this.TrBufPrice    = nan(nT,1);
            this.TrBufNotional = nan(nT,1);
            this.TrBufFee      = nan(nT,1);
            this.TrBufTax      = nan(nT,1);
            this.TrBufReason   = strings(nT,1);

            % Borrow buffer
            nB = max(1, round(this.BorrowBufSize));
            this.BrBufN = 0;
            this.BrBufTime     = NaT(nB,1);
            this.BrBufSymbol   = strings(nB,1);
            this.BrBufTraderId = strings(nB,1);
            this.BrBufCost     = nan(nB,1);
        end

        % -------- Dependent getters (auto flush) --------
        function T = get.TradeLog(this)
            this.flush_trade_buffer();
            T = this.TradeLog_;
        end

        function B = get.BorrowLog(this)
            this.flush_borrow_buffer();
            B = this.BorrowLog_;
        end

        function EC = get.EquityCurve(this)
            this.flush_equity_buffer();
            EC = this.EquityCurve_;
        end

        % -------- Core helpers --------
        function p = get_position(this, symbol)
            key = char(string(symbol));
            if isKey(this.Positions, key)
                p = this.Positions(key);
            else
                p = position(symbol);
                this.Positions(key) = p;
            end
        end

        function update_last_prices(this, priceMap)
            if nargin < 2 || isempty(priceMap) || ~isa(priceMap,'containers.Map')
                return;
            end
            ks = priceMap.keys;
            for i = 1:numel(ks)
                k = ks{i};
                this.LastPrices(k) = double(priceMap(k));
            end
        end

        function update_margin(this, priceMap, specMap)
            m = 0.0;
            if nargin < 3 || isempty(specMap) || ~isa(specMap,'containers.Map')
                this.ReservedMargin = 0.0;
                return;
            end

            ks = this.Positions.keys;
            for i = 1:numel(ks)
                k = ks{i};
                pos = this.Positions(k);
                if pos.Qty == 0
                    continue;
                end

                px = double(pos.AvgPrice);
                if nargin >= 2 && ~isempty(priceMap) && isa(priceMap,'containers.Map') && isKey(priceMap,k)
                    px = double(priceMap(k));
                elseif isKey(this.LastPrices,k)
                    px = double(this.LastPrices(k));
                end

                if isKey(specMap, k)
                    spec = specMap(k);
                    m = m + double(spec.required_margin(double(pos.Qty), px));
                end
            end
            this.ReservedMargin = m;
        end

        function eq = compute_equity(this, priceMap, specMap)
            eq = this.Cash;
            ks = this.Positions.keys;
            for i = 1:numel(ks)
                k = ks{i};
                pos = this.Positions(k);
                if pos.Qty == 0
                    continue;
                end

                px = double(pos.AvgPrice);
                if nargin >= 2 && ~isempty(priceMap) && isa(priceMap,'containers.Map') && isKey(priceMap,k)
                    px = double(priceMap(k));
                elseif isKey(this.LastPrices,k)
                    px = double(this.LastPrices(k));
                end

                mult = 1.0;
                if nargin >= 3
                    [~, mult] = portfolio_account.owner_mult(k, specMap);
                end
                eq = eq + double(pos.Qty) * px * mult;
            end
        end

        function [grossExp, netExp] = exposures(this, priceMap, specMap)
            grossExp = 0.0; netExp = 0.0;
            ks = this.Positions.keys;
            for i = 1:numel(ks)
                k = ks{i};
                pos = this.Positions(k);
                if pos.Qty == 0
                    continue;
                end

                px = double(pos.AvgPrice);
                if nargin >= 2 && ~isempty(priceMap) && isa(priceMap,'containers.Map') && isKey(priceMap,k)
                    px = double(priceMap(k));
                elseif isKey(this.LastPrices,k)
                    px = double(this.LastPrices(k));
                end

                mult = 1.0;
                if nargin >= 3
                    [~, mult] = portfolio_account.owner_mult(k, specMap);
                end

                n = double(pos.Qty) * px * mult;
                grossExp = grossExp + abs(n);
                netExp = netExp + n;
            end
        end

        function avail = available_cash(this)
            avail = this.Cash - this.ReservedMargin;
        end

        % -------- Execution / accounting --------
        function ok = set_target_qty(this, dt, symbol, targetQty, price, spec, specMap, traderId, reason)
            % Stable signature (avoid varargin). Engine calls:
            %   set_target_qty(dt, sym, tq, px, spec, specMap, traderId)
            % Optional: reason (9th arg)
            if nargin < 7, specMap = []; end
            if nargin < 8 || isempty(traderId), traderId = ""; end
            if nargin < 9 || isempty(reason),  reason  = ""; end
            key = char(string(symbol));
            p = this.get_position(key);

            targetQty = double(targetQty);
            qtyDelta = targetQty - double(p.Qty);
            if abs(qtyDelta) < 1e-12
                ok = true;
                return;
            end

            ok = this.execute_trade(dt, key, qtyDelta, price, spec, specMap, traderId, reason);
        end

        function ok = execute_trade(this, dt, symKey, qtyDelta, price, spec, specMap, traderId, reason)
            ok = true;


            if nargin < 6, specMap = []; end
            if nargin < 7 || isempty(traderId), traderId = ""; end
            if nargin < 8 || isempty(reason),  reason  = ""; end
            qtyDelta = double(qtyDelta);
            price = double(price);

            if ~isfinite(price) || price <= 0
                ok = false;
                return;
            end

            p = this.get_position(symKey);

            % Short permission check
            newQty = p.simulate_after_trade(qtyDelta, price);
            if numel(newQty) > 1
                newQty = newQty(1);
            end
            if double(newQty) < 0 && isprop(spec,'AllowShort') && ~spec.AllowShort
                ok = false;
                return;
            end

            side = "BUY";
            if qtyDelta < 0
                side = "SELL";
            end

            mult = 1.0;
            traderId = "";
            if ~isempty(spec)
                if isprop(spec,'Multiplier'); mult = double(spec.Multiplier); end
                if isprop(spec,'TraderId'); traderId = string(spec.TraderId); end
            end
            if traderId == "" && nargin >= 6
                [traderId2, mult2] = portfolio_account.owner_mult(symKey, specMap);
                if traderId2 ~= ""; traderId = traderId2; end
                mult = mult2;
            end

            notionalAbs = abs(qtyDelta * price * mult);

            fee = 0.0; tax = 0.0;
            if ismethod(spec,'trade_fee'); fee = double(spec.trade_fee(notionalAbs)); end
            if ismethod(spec,'trade_tax'); tax = double(spec.trade_tax(dt, side, notionalAbs)); end

            cashChange = -(qtyDelta * price * mult);
            newCash = this.Cash + cashChange - fee - tax;

            % Margin check (simple; uses LastPrices + trade price)
            if nargin >= 6 && ~isempty(specMap) && isa(specMap,'containers.Map')
                pm = this.LastPrices;
                pm(symKey) = price;

                m = 0.0;
                ks = this.Positions.keys;
                for i=1:numel(ks)
                    k2 = ks{i};
                    pos2 = this.Positions(k2);
                    q2 = double(pos2.Qty);
                    if strcmp(k2, symKey)
                        q2 = double(newQty);
                    end
                    if q2 == 0
                        continue;
                    end

                    px2 = double(pos2.AvgPrice);
                    if isKey(pm, k2)
                        px2 = double(pm(k2));
                    end

                    if isKey(specMap, k2)
                        m = m + double(specMap(k2).required_margin(q2, px2));
                    end
                end

                if newCash - m < -1e-9
                    ok = false;
                    return;
                end
            end

            % Apply trade
            p.apply_trade(qtyDelta, price);

            this.Cash = newCash;
            this.FeesPaid = this.FeesPaid + fee;
            this.TaxesPaid = this.TaxesPaid + tax;
            this.LastPrices(symKey) = price;

            % Log (buffered)
            this.push_trade_row(dt, string(symKey), traderId, "TRADE", side, ...
                qtyDelta, double(p.Qty), price, notionalAbs, fee, tax, portfolio_account.safe_str(reason));
        end

        function apply_borrow_cost(this, dt, priceMap, specMap, tradingDays)
            if nargin < 5 || isempty(tradingDays)
                tradingDays = 252;
            end
            if nargin < 4 || isempty(specMap) || ~isa(specMap,'containers.Map')
                return;
            end
            if nargin < 3 || isempty(priceMap) || ~isa(priceMap,'containers.Map')
                priceMap = containers.Map('KeyType','char','ValueType','double');
            end

            costTotal = 0.0;
            ks = this.Positions.keys;
            for i = 1:numel(ks)
                k = ks{i};
                pos = this.Positions(k);
                if double(pos.Qty) >= 0
                    continue;
                end
                if ~isKey(specMap, k)
                    continue;
                end
                spec = specMap(k);
                if ~isprop(spec,'BorrowRateAnnual') || double(spec.BorrowRateAnnual) <= 0
                    continue;
                end

                px = double(pos.AvgPrice);
                if isKey(priceMap, k)
                    px = double(priceMap(k));
                elseif isKey(this.LastPrices, k)
                    px = double(this.LastPrices(k));
                end

                [owner, mult] = portfolio_account.owner_mult(k, specMap);
                notionalAbs = abs(double(pos.Qty) * px * mult);
                cost = notionalAbs * (double(spec.BorrowRateAnnual) / tradingDays);

                if cost > 0
                    costTotal = costTotal + cost;
                    this.push_borrow_row(dt, string(k), owner, cost);
                end
            end

            if costTotal > 0
                this.Cash = this.Cash - costTotal;
                this.BorrowPaid = this.BorrowPaid + costTotal;
            end
        end

        function append_equity_curve(this, dt, priceMap, specMap)
            this.update_last_prices(priceMap);
            this.update_margin(priceMap, specMap);

            eq = this.compute_equity(priceMap, specMap);
            [g, n] = this.exposures(priceMap, specMap);

            this.push_equity_row(dt, eq, this.Cash, this.ReservedMargin, g, n);
        end

        % -------- Reports --------
        function R = report(this, priceMap, specMap, varargin)
            p = inputParser;
            p.addParameter('TraderId', "", @(x) isstring(x) || ischar(x));
            p.parse(varargin{:});
            traderId = string(p.Results.TraderId);

            this.flush_all();

            eq = this.compute_equity(priceMap, specMap);
            R = struct();
            R.Equity = eq;
            R.Cash = this.Cash;
            R.ReservedMargin = this.ReservedMargin;

            [posAll, posSummary] = this.build_positions_tables(priceMap, specMap);
            if traderId ~= ""
                posAll = posAll(posAll.TraderId == traderId, :);
                posSummary = posSummary(posSummary.TraderId == traderId, :);
            end
            R.OpenPositions = posAll(posAll.Qty ~= 0, :);
            R.PositionsSummary = posSummary;

            T = this.TradeLog_;
            B = this.BorrowLog_;
            if traderId ~= ""
                T = T(T.TraderId == traderId, :);
                B = B(B.TraderId == traderId, :);
            end
            R.Trades = T;
            R.Borrows = B;

            R.Fees = sum(double(T.Fee));
            R.Taxes = sum(double(T.Tax));
            R.Borrow = sum(double(B.Cost));

            R.ContributionPnL = nan;
            if ~isempty(posSummary)
                rp = sum(double(posSummary.RealizedPnL));
                up = sum(double(posSummary.UnrealizedPnL));
                R.ContributionPnL = (rp + up) - (R.Fees + R.Taxes + R.Borrow);
            end

            if traderId ~= ""
                R.Note = "Cash/Equity are portfolio-wide (shared wallet). Costs/PnL are filtered by TraderId.";
            else
                R.Note = "Cash/Equity are portfolio-wide. Use TraderId filter for strategy attribution.";
            end
        end

        function flush_all(this)
            this.flush_trade_buffer();
            this.flush_borrow_buffer();
            this.flush_equity_buffer();
        end
    end

    methods (Access=private)
        % -------- Buffer push/flush --------
        function push_equity_row(this, dt, eq, cash, resM, g, n)
            i = this.EqBufN + 1;
            if i > numel(this.EqBufEquity)
                this.flush_equity_buffer();
                i = 1;
            end
            this.EqBufDt(i)       = dt;
            this.EqBufEquity(i)   = double(eq);
            this.EqBufCash(i)     = double(cash);
            this.EqBufResM(i)     = double(resM);
            this.EqBufGrossExp(i) = double(g);
            this.EqBufNetExp(i)   = double(n);
            this.EqBufN = i;

            if this.EqBufN >= numel(this.EqBufEquity)
                this.flush_equity_buffer();
            end
        end

        function flush_equity_buffer(this)
            n = this.EqBufN;
            if n <= 0
                return;
            end
            dt = this.EqBufDt(1:n);
            eq = this.EqBufEquity(1:n);
            ca = this.EqBufCash(1:n);
            rm = this.EqBufResM(1:n);
            ge = this.EqBufGrossExp(1:n);
            ne = this.EqBufNetExp(1:n);

            TT = timetable(dt, eq, ca, rm, ge, ne, ...
                'VariableNames', {'Equity','Cash','ReservedMargin','GrossExposure','NetExposure'});
            TT.Properties.DimensionNames{1} = 'dt';
            this.EquityCurve_ = [this.EquityCurve_; TT]; %#ok<AGROW>

            this.EqBufN = 0;
        end

        function push_trade_row(this, dt, sym, traderId, action, side, qtyDelta, qtyAfter, price, notionalAbs, fee, tax, reason)
            i = this.TrBufN + 1;
            if i > numel(this.TrBufPrice)
                this.flush_trade_buffer();
                i = 1;
            end
            this.TrBufTime(i)     = dt;
            this.TrBufSymbol(i)   = string(sym);
            this.TrBufTraderId(i) = string(traderId);
            this.TrBufAction(i)   = string(action);
            this.TrBufSide(i)     = string(side);
            this.TrBufQtyDelta(i) = double(qtyDelta);
            this.TrBufQtyAfter(i) = double(qtyAfter);
            this.TrBufPrice(i)    = double(price);
            this.TrBufNotional(i) = double(notionalAbs);
            this.TrBufFee(i)      = double(fee);
            this.TrBufTax(i)      = double(tax);
            this.TrBufReason(i)   = string(reason);

            this.TrBufN = i;

            if this.TrBufN >= numel(this.TrBufPrice)
                this.flush_trade_buffer();
            end
        end

        function flush_trade_buffer(this)
            n = this.TrBufN;
            if n <= 0
                return;
            end
            rows = table( ...
                this.TrBufTime(1:n), ...
                this.TrBufSymbol(1:n), ...
                this.TrBufTraderId(1:n), ...
                this.TrBufAction(1:n), ...
                this.TrBufSide(1:n), ...
                this.TrBufQtyDelta(1:n), ...
                this.TrBufQtyAfter(1:n), ...
                this.TrBufPrice(1:n), ...
                this.TrBufNotional(1:n), ...
                this.TrBufFee(1:n), ...
                this.TrBufTax(1:n), ...
                this.TrBufReason(1:n), ...
                'VariableNames', this.TradeLog_.Properties.VariableNames);
            this.TradeLog_ = [this.TradeLog_; rows]; %#ok<AGROW>
            this.TrBufN = 0;
        end

        function push_borrow_row(this, dt, sym, traderId, cost)
            i = this.BrBufN + 1;
            if i > numel(this.BrBufCost)
                this.flush_borrow_buffer();
                i = 1;
            end
            this.BrBufTime(i)     = dt;
            this.BrBufSymbol(i)   = string(sym);
            this.BrBufTraderId(i) = string(traderId);
            this.BrBufCost(i)     = double(cost);
            this.BrBufN = i;

            if this.BrBufN >= numel(this.BrBufCost)
                this.flush_borrow_buffer();
            end
        end

        function flush_borrow_buffer(this)
            n = this.BrBufN;
            if n <= 0
                return;
            end
            rows = table( ...
                this.BrBufTime(1:n), ...
                this.BrBufSymbol(1:n), ...
                this.BrBufTraderId(1:n), ...
                this.BrBufCost(1:n), ...
                'VariableNames', this.BorrowLog_.Properties.VariableNames);
            this.BorrowLog_ = [this.BorrowLog_; rows]; %#ok<AGROW>
            this.BrBufN = 0;
        end

        function [openPos, summary] = build_positions_tables(this, priceMap, specMap)
            ks = this.Positions.keys;
            n = numel(ks);

            Symbol = strings(n,1);
            TraderId = strings(n,1);
            Qty = nan(n,1);
            AvgPrice = nan(n,1);
            LastPrice = nan(n,1);
            Multiplier = nan(n,1);
            Notional = nan(n,1);
            RealizedPnL = nan(n,1);
            UnrealizedPnL = nan(n,1);

            for i = 1:n
                k = ks{i};
                pos = this.Positions(k);

                Symbol(i) = string(k);
                [owner, mult] = portfolio_account.owner_mult(k, specMap);
                TraderId(i) = owner;
                Multiplier(i) = mult;

                Qty(i) = double(pos.Qty);
                AvgPrice(i) = double(pos.AvgPrice);

                px = AvgPrice(i);
                if nargin >= 2 && ~isempty(priceMap) && isa(priceMap,'containers.Map') && isKey(priceMap,k)
                    px = double(priceMap(k));
                elseif isKey(this.LastPrices,k)
                    px = double(this.LastPrices(k));
                end
                LastPrice(i) = px;

                Notional(i) = Qty(i) * px * mult;

                if isprop(pos,'RealizedPnL')
                    RealizedPnL(i) = double(pos.RealizedPnL);
                end
                UnrealizedPnL(i) = (px - AvgPrice(i)) * Qty(i) * mult;
            end

            openPos = table(Symbol, TraderId, Qty, AvgPrice, LastPrice, Multiplier, Notional, RealizedPnL, UnrealizedPnL);
            summary = openPos;
        end
    end

    methods (Static, Access=private)
        function [owner, mult] = owner_mult(symKey, specMap)
            % owner_mult(symKey, specMap)
            %
            % Returns:
            %   owner : string TraderId ("" if unknown)
            %   mult  : double multiplier (1.0 if unknown)
            %
            % IMPORTANT:
            %   This helper must NOT reference nargin>=3 when it only has two
            %   inputs. Earlier drafts had that bug.
            owner = "";
            mult = 1.0;

            if nargin < 2 || isempty(specMap) || ~isa(specMap,'containers.Map')
                return;
            end
            if ~isKey(specMap, symKey)
                return;
            end

            sp = specMap(symKey);

            if isprop(sp,'Multiplier')
                mult = double(sp.Multiplier);
            end
            if isprop(sp,'TraderId')
                owner = string(sp.TraderId);
            elseif isprop(sp,'Owner')
                owner = string(sp.Owner);
            end
        end
        function s = safe_str(x)
            % safe_str: robust conversion to string for logging.
            % Ensures we never crash if x is not string/char.
            try
                if isstring(x) || ischar(x)
                    s = string(x);
                elseif isempty(x)
                    s = "";
                else
                    % Avoid expensive conversions (e.g., containers.Map)
                    s = "<" + string(class(x)) + ">";
                end
            catch
                s = "";
            end
        end
    end
end
