classdef ticker_data_manager < handle
    % ticker_data_manager (panel CSV version)
    % - Read panel CSV that contains multiple tickers
    % - Filter to a specified ticker and store OHLC
    % - Precompute SMAs: 5/20/40/180
    % - Long-term trend: compare SMA180(t) vs SMA180(t-20) => -1/0/+1

    properties (SetAccess=private)
        PanelFile string = ""

        T table
        Ticker string = ""
        Name string = ""

        Date datetime
        Open double
        High double
        Low double
        Close double

        smaWeek double
        smaFast double
        smaSlow double
        smaLongTerm double

        atr double

        longTermTrend int8
    end

    properties (Constant)
        WEEK_N = 5
        FAST_N = 20
        SLOW_N = 40
        LONGTERM_N = 180
        ATR_N = 14
        LONGTREND_LOOKBACK = 20
    end

    methods
        function this = ticker_data_manager(panelCsvFile, ticker)
            % Constructor (nargin-based for compatibility)
            if nargin < 2
                error("ticker_data_manager:ctor","panelCsvFile and ticker are required.");
            end
            panelCsvFile = string(panelCsvFile);
            ticker = string(ticker);

this.PanelFile = panelCsvFile;

            if ~isfile(panelCsvFile)
                error("ticker_data_manager:FileNotFound", "파일을 찾을 수 없습니다: %s", panelCsvFile);
            end

            T0 = readtable(panelCsvFile, "TextType","string");
            T0 = this.standardize_columns(T0);

            % Normalize Ticker column in table (important)
            if ~ismember("Ticker", string(T0.Properties.VariableNames))
                error("ticker_data_manager:MissingTicker", "패널 CSV에 'Ticker' 컬럼이 필요합니다.");
            end

            T0.Ticker = normalize_ticker_6(T0.Ticker);
            tk = normalize_ticker_6(ticker);

            T1 = T0(T0.Ticker == tk, :);
            if height(T1) < 10
                error("ticker_data_manager:NotEnoughData", ...
                    "티커 %s에 대한 데이터가 충분하지 않습니다. (rows=%d)", tk, height(T1));
            end

            T1.Date = datetime(T1.Date);
            T1 = sortrows(T1, "Date");

            this.T = T1;
            this.Ticker = tk;

            if ismember("Name", string(T1.Properties.VariableNames))
                this.Name = string(T1.Name(1));
            else
                this.Name = "";
            end

            this.Date  = T1.Date;
            this.Open  = double(T1.Open);
            this.High  = double(T1.High);
            this.Low   = double(T1.Low);
            this.Close = double(T1.Close);

            % Basic sanity filter (optional)
            good = isfinite(this.Open) & isfinite(this.High) & isfinite(this.Low) & isfinite(this.Close) & ...
                   this.Open>0 & this.High>0 & this.Low>0 & this.Close>0;
            this.Date = this.Date(good);
            this.Open = this.Open(good);
            this.High = this.High(good);
            this.Low  = this.Low(good);
            this.Close= this.Close(good);

            % Precompute SMAs
            this.smaWeek     = movmean(this.Close, [this.WEEK_N-1 0], "omitnan");
            this.smaFast     = movmean(this.Close, [this.FAST_N-1 0], "omitnan");
            this.smaSlow     = movmean(this.Close, [this.SLOW_N-1 0], "omitnan");
            this.smaLongTerm = movmean(this.Close, [this.LONGTERM_N-1 0], "omitnan");

            % ATR (True Range moving average)
            this.atr = this.compute_atr(this.ATR_N);

            % Long-term trend
            this.longTermTrend = this.compute_long_term_trend();
        end

        function n = length(this)
            n = numel(this.Date);
        end

        function tickers = list_tickers(panelCsvFile)
            % Static-like convenience (call as ticker_data_manager.list_tickers(...))
            T0 = readtable(panelCsvFile, "TextType","string");
            T0 = ticker_data_manager.static_standardize_columns(T0);
            if ~ismember("Ticker", string(T0.Properties.VariableNames))
                error("패널 CSV에 'Ticker' 컬럼이 필요합니다.");
            end
            tickers = unique(normalize_ticker_6(T0.Ticker), "stable");
        end

        function ctx = get_ctx_prev(this, t)
            if t < 3
                ctx = struct(); ctx.valid = false; return;
            end
            ctx = struct();
            ctx.valid = true;
            ctx.date = this.Date(t);

            ctx.smaWeek_prev      = this.smaWeek(t-1);
            ctx.smaFast_prev      = this.smaFast(t-1);
            ctx.smaSlow_prev      = this.smaSlow(t-1);
            ctx.smaLongTerm_prev  = this.smaLongTerm(t-1);
            ctx.smaLongTerm_prev2 = this.smaLongTerm(t-2);

            ctx.atr_prev = this.atr(t-1);

            ctx.longTermTrend_prev = this.longTermTrend(t-1);
        end

        function [d0, d1] = data_range(this)
            d0 = this.Date(1);
            d1 = this.Date(end);
        end
    
        function idx = indices_in_range(this, startDate, endDate)
            % Returns indices of this.Date within [startDate, endDate]
            idx = find(this.Date >= startDate & this.Date <= endDate);
        end
    end

    methods (Access=private)
        function trend = compute_long_term_trend(this)
            n = numel(this.smaLongTerm);
            trend = zeros(n,1,"int8");
            lb = this.LONGTREND_LOOKBACK;

            for i = 1:n
                if i <= lb || ~isfinite(this.smaLongTerm(i)) || ~isfinite(this.smaLongTerm(i-lb))
                    trend(i) = int8(0);
                else
                    if this.smaLongTerm(i) > this.smaLongTerm(i-lb)
                        trend(i) = int8(1);
                    elseif this.smaLongTerm(i) < this.smaLongTerm(i-lb)
                        trend(i) = int8(-1);
                    else
                        trend(i) = int8(0);
                    end
                end
            end
        end

        function atr = compute_atr(this, n)
            % Compute ATR as moving average of True Range (simple MA)
            % TR(t) = max( High-Low, abs(High-ClosePrev), abs(Low-ClosePrev) )
            % atr(t) = movmean(TR, [n-1 0])
            H = this.High(:);
            L = this.Low(:);
            C = this.Close(:);

            cp = [NaN; C(1:end-1)];
            tr = max([H-L, abs(H-cp), abs(L-cp)], [], 2);
            atr = movmean(tr, [n-1 0], "omitnan");
        end

        function T = standardize_columns(~, T)
            T = ticker_data_manager.static_standardize_columns(T);
        end
    end

    methods (Static, Access=private)
        function T = static_standardize_columns(T)
            vn = string(T.Properties.VariableNames);

            map = containers.Map( ...
                ["date","Date","날짜","DATE", ...
                 "open","Open","시가", ...
                 "high","High","고가", ...
                 "low","Low","저가", ...
                 "close","Close","종가", ...
                 "ticker","Ticker","code","Code","종목코드", ...
                 "name","Name","종목명"], ...
                ["Date","Date","Date","Date", ...
                 "Open","Open","Open", ...
                 "High","High","High", ...
                 "Low","Low","Low", ...
                 "Close","Close","Close", ...
                 "Ticker","Ticker","Ticker","Ticker","Ticker", ...
                 "Name","Name","Name"] ...
            );

            newNames = vn;
            for i=1:numel(vn)
                key = vn(i);
                if isKey(map, key)
                    newNames(i) = map(key);
                else
                    k2 = lower(key);
                    if isKey(map, k2)
                        newNames(i) = map(k2);
                    end
                end
            end
            T.Properties.VariableNames = cellstr(newNames);

            required = ["Date","Ticker","Open","High","Low","Close"];
            for r = required
                if ~ismember(r, string(T.Properties.VariableNames))
                    error("ticker_data_manager:MissingColumn", ...
                        "패널 CSV에 필수 컬럼 '%s'가 없습니다. 현재 컬럼: %s", ...
                        r, strjoin(string(T.Properties.VariableNames), ", "));
                end
            end
        end
    end
end

function s = normalize_ticker_6(x)
    if isnumeric(x)
        s = string(compose("%06d", x(:)));
        return;
    end
    x = string(x);
    x = strtrim(x);
    x = regexprep(x, "\.0+$", "");
    s = strings(size(x));
    for i=1:numel(x)
        if strlength(x(i))==0 || ismissing(x(i))
            s(i)=missing; continue;
        end
        if all(isstrprop(x(i),'digit'))
            s(i)=compose("%06d", str2double(x(i)));
        else
            s(i)=x(i);
        end
    end
end
