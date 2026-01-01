classdef portfolio_account < handle
    % portfolio_account
    % Portfolio-level cash, positions, margin and accounting.

    properties
        InitialCapital double = 0.0
        Cash double = 0.0

        Positions containers.Map
        ReservedMargin double = 0.0

        RealizedPnL double = 0.0
        FeesPaid double = 0.0
        TaxesPaid double = 0.0
        BorrowPaid double = 0.0

        LastPrices containers.Map  % symbol->last price (used for margin checks)

        TradeLog table
        EquityCurve timetable
    end

    methods
        function this = portfolio_account(initialCapital)
            if nargin < 1 || isempty(initialCapital)
                initialCapital = 0;
            end
            this.InitialCapital = double(initialCapital);
            this.Cash = this.InitialCapital;

            this.Positions = containers.Map('KeyType','char','ValueType','any');
            this.LastPrices = containers.Map('KeyType','char','ValueType','double');

            this.TradeLog = table('Size',[0 11], ...
                'VariableTypes', ["datetime","string","string","string","double","double","double","double","double","double","string"], ...
                'VariableNames', ["Time","Symbol","Action","Side","QtyDelta","QtyAfter","Price","Notional","Fee","Tax","Reason"]);

            % Equity curve: one row per timestamp.
            % IMPORTANT: Number of variables must match VariableNames.
            this.EquityCurve = timetable(...
                datetime.empty(0,1), ... % RowTimes
                double.empty(0,1), ...   % Equity
                double.empty(0,1), ...   % Cash
                double.empty(0,1), ...   % ReservedMargin
                double.empty(0,1), ...   % GrossExposure
                double.empty(0,1), ...   % NetExposure
                'VariableNames', {'Equity','Cash','ReservedMargin','GrossExposure','NetExposure'});
        end

        function p = get_position(this, symbol)
            key = char(string(symbol));
            if isKey(this.Positions, key)
                p = this.Positions(key);
            else
                p = position(symbol);
                this.Positions(key) = p;
            end
        end

        function eq = compute_equity(this, priceMap, specMap)
            %#ok<INUSD>
            eq = this.Cash;
            ks = this.Positions.keys;
            for i = 1:numel(ks)
                k = ks{i};
                pos = this.Positions(k);
                if pos.Qty == 0
                    continue;
                end
                if isKey(priceMap, k)
                    px = priceMap(k);
                else
                    px = pos.AvgPrice;
                end
                mult = 1.0;
                if nargin >= 3 && ~isempty(specMap) && isKey(specMap, k)
                    mult = specMap(k).Multiplier;
                end
                eq = eq + pos.Qty * px * mult;
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
                if isKey(priceMap, k)
                    px = priceMap(k);
                else
                    px = pos.AvgPrice;
                end
                mult = 1.0;
                if nargin >= 3 && ~isempty(specMap) && isKey(specMap, k)
                    mult = specMap(k).Multiplier;
                end
                n = pos.Qty * px * mult;
                grossExp = grossExp + abs(n);
                netExp = netExp + n;
            end
        end

        function avail = available_cash(this)
            avail = this.Cash - this.ReservedMargin;
        end

        function update_last_prices(this, priceMap)
            ks = priceMap.keys;
            for i=1:numel(ks)
                k = ks{i};
                this.LastPrices(k) = double(priceMap(k));
            end
        end

        function update_margin(this, priceMap, specMap)
            m = 0.0;
            ks = this.Positions.keys;
            for i = 1:numel(ks)
                k = ks{i};
                pos = this.Positions(k);
                if pos.Qty == 0
                    continue;
                end
                if isKey(priceMap, k)
                    px = priceMap(k);
                elseif isKey(this.LastPrices, k)
                    px = this.LastPrices(k);
                else
                    px = pos.AvgPrice;
                end

                if ~isempty(specMap) && isKey(specMap, k)
                    spec = specMap(k);
                    m = m + spec.required_margin(pos.Qty, px);
                end
            end
            this.ReservedMargin = m;
        end

        function apply_borrow_cost(this, dt, priceMap, specMap, tradingDays)
            if nargin < 5 || isempty(tradingDays)
                tradingDays = 252;
            end
            % Defensive: accept only containers.Map inputs
            if nargin < 4 || isempty(specMap) || ~isa(specMap,'containers.Map')
                return;
            end
            if nargin < 3 || isempty(priceMap) || ~isa(priceMap,'containers.Map')
                priceMap = containers.Map('KeyType','char','ValueType','double');
            end
            cost = 0.0;
            ks = this.Positions.keys;
            for i = 1:numel(ks)
                k = ks{i};
                pos = this.Positions(k);
                if pos.Qty >= 0
                    continue;
                end
                if ~isKey(specMap, k)
                    continue;
                end
                spec = specMap(k);
                if spec.BorrowRateAnnual <= 0
                    continue;
                end
                if isKey(priceMap, k)
                    px = priceMap(k);
                elseif isKey(this.LastPrices, k)
                    px = this.LastPrices(k);
                else
                    px = pos.AvgPrice;
                end
                notionalAbs = abs(pos.Qty * px * spec.Multiplier);
                cost = cost + notionalAbs * (spec.BorrowRateAnnual / tradingDays);
            end
            if cost > 0
                this.Cash = this.Cash - cost;
                this.BorrowPaid = this.BorrowPaid + cost;
            end
            %#ok<NASGU>
        end

        function ok = set_target_qty(this, dt, symbol, targetQty, price, spec, reason, specMap)
            % Adjust position to a target quantity at given execution price.
            % Returns ok=false when rejected by cash/margin constraints.
            if nargin < 8, specMap = []; end
            if nargin < 7 || isempty(reason), reason = ""; end

            symbol = string(symbol);
            key = char(symbol);
            p = this.get_position(symbol);

            targetQty = double(targetQty);
            qtyDelta = targetQty - double(p.Qty);
            if abs(qtyDelta) < 1e-12
                ok = true;
                return;
            end

            ok = this.execute_trade(dt, key, qtyDelta, price, spec, reason, specMap);
        end

        function ok = execute_trade(this, dt, key, qtyDelta, price, spec, reason, specMap)
            ok = true;

            qtyDelta = double(qtyDelta);
            price = double(price);
            if ~isfinite(price) || price <= 0
                ok = false;
                return;
            end

            p = this.get_position(key);

            % Short permission check
            [newQty, ~, ~] = p.simulate_after_trade(qtyDelta, price);
            if newQty < 0 && ~spec.AllowShort
                ok = false;
                return;
            end

            side = "BUY";
            if qtyDelta < 0
                side = "SELL";
            end

            notionalAbs = abs(qtyDelta * price * spec.Multiplier);
            fee = spec.trade_fee(notionalAbs);
            tax = spec.trade_tax(dt, side, notionalAbs);

            cashChange = -(qtyDelta * price * spec.Multiplier);
            newCash = this.Cash + cashChange - fee - tax;

            % --- tentative margin check (simple, uses LastPrices + trade price) ---
            if isempty(specMap)
                % fall back: do not reject (but still apply newCash)
            else
                % Copy last prices (may be empty)
                if this.LastPrices.Count == 0
                    pm = containers.Map('KeyType','char','ValueType','double');
                else
                    pm = containers.Map(this.LastPrices.keys, cell2mat(values(this.LastPrices)));
                end
                pm(key) = price;

                % compute margin with simulated new position
                tmpQty = newQty;
                m = 0.0;
                ks = this.Positions.keys;
                for i=1:numel(ks)
                    k2 = ks{i};
                    pos2 = this.Positions(k2);
                    q2 = pos2.Qty;
                    if strcmp(k2, key)
                        q2 = tmpQty;
                    end
                    if q2 == 0
                        continue;
                    end
                    if isKey(pm, k2)
                        px2 = pm(k2);
                    else
                        px2 = pos2.AvgPrice;
                    end
                    if isKey(specMap, k2)
                        m = m + specMap(k2).required_margin(q2, px2);
                    end
                end

                if newCash - m < -1e-9
                    ok = false;
                    return;
                end
            end

            % --- apply trade ---
            eqBefore = this.compute_equity(this.LastPrices, specMap);

            p.apply_trade(qtyDelta, price);
            this.RealizedPnL = this.RealizedPnL + 0; % realized tracked per-position

            this.Cash = newCash;
            this.FeesPaid = this.FeesPaid + fee;
            this.TaxesPaid = this.TaxesPaid + tax;

            % remember last execution price for this symbol
            this.LastPrices(key) = price;

            % log
            this.TradeLog = [this.TradeLog; {dt, string(key), "TRADE", side, qtyDelta, p.Qty, price, notionalAbs, fee, tax, string(reason)}]; %#ok<AGROW>

            %#ok<NASGU>
            eqAfter = eqBefore; % kept for potential extension
        end

        function append_equity_curve(this, dt, priceMap, specMap)
            this.update_last_prices(priceMap);
            this.update_margin(priceMap, specMap);
            eq = this.compute_equity(priceMap, specMap);
            [g, n] = this.exposures(priceMap, specMap);
            this.EquityCurve = [this.EquityCurve; timetable(dt, eq, this.Cash, this.ReservedMargin, g, n, ...
                'VariableNames', {'Equity','Cash','ReservedMargin','GrossExposure','NetExposure'})]; %#ok<AGROW>
        end
    end
end
