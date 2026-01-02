classdef ticker_data_manager < handle
    % ticker_data_manager (MACD + close_prev + optional [startDate,endDate], signature compatible)
    %
    % Backward compatible constructors:
    %   dm = ticker_data_manager(panelCsvFile, ticker)
    %   dm = ticker_data_manager(panelCsvFile, ticker, startDate, endDate)
    %
    % If start/end are provided, the data is trimmed to [start,end] plus warmup bars.

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

        % MACD
        macdLine double
        macdSignal double
        macdHist double
    end

    properties (Constant)
        WEEK_N = 5
        FAST_N = 20
        SLOW_N = 40
        LONGTERM_N = 180
        ATR_N = 14
        LONGTREND_LOOKBACK = 20

        MACD_FAST = 12
        MACD_SLOW = 26
        MACD_SIGNAL = 9
    end

    methods
        function this = ticker_data_manager(panelCsvFile, ticker, varargin)
            if nargin < 2
                error("ticker_data_manager:ctor","panelCsvFile and ticker are required.");
            end
            %     panelCsvFile = string(panelCsvFile);
            % ticker = string(ticker);

            this.PanelFile = panelCsvFile;

            if ~isfile(panelCsvFile)
                error("ticker_data_manager:FileNotFound", "파일을 찾을 수 없습니다: %s", panelCsvFile);
            end

            % Optional args
            startDate = [];
            endDate   = [];
            if numel(varargin) >= 1 && ~isempty(varargin{1}), startDate = varargin{1}; end
            if numel(varargin) >= 2 && ~isempty(varargin{2}), endDate   = varargin{2}; end
            if ~isempty(startDate) && ~isdatetime(startDate), startDate = datetime(startDate); end
            if ~isempty(endDate)   && ~isdatetime(endDate),   endDate   = datetime(endDate);   end

            % Read panel table (cached per MATLAB session to avoid repeated I/O)
            persistent PANEL_CACHE_PATH PANEL_CACHE_T
            if ~isempty(PANEL_CACHE_PATH) && PANEL_CACHE_PATH == panelCsvFile && ~isempty(PANEL_CACHE_T)
                T0 = PANEL_CACHE_T;
            else
                T0 = readtable(panelCsvFile, "TextType","string");
                PANEL_CACHE_PATH = panelCsvFile;
                PANEL_CACHE_T = T0;
            end

            T0 = this.standardize_columns(T0);

            T0.Ticker = ticker_data_manager.normalize_ticker_6(T0.Ticker);
            tk = ticker_data_manager.normalize_ticker_6(ticker);

            T1 = T0(T0.Ticker == tk, :);
            if height(T1) < 10
                error("ticker_data_manager:NotEnoughData", ...
                    "티커 %s에 대한 데이터가 충분하지 않습니다. (rows=%d)", tk, height(T1));
            end

            T1.Date = datetime(T1.Date);
            T1 = sortrows(T1, "Date");

            % Optional: trim data to backtest window (with warmup bars)
            if ~isempty(startDate) && ~isempty(endDate)
                warmupBars = max([this.LONGTERM_N, this.ATR_N, this.SLOW_N, (this.MACD_SLOW + 3*this.MACD_SIGNAL), 250]);

                firstIdx = find(T1.Date >= startDate, 1, 'first');
                lastIdx  = find(T1.Date <= endDate,   1, 'last');

                if isempty(firstIdx) || isempty(lastIdx) || firstIdx > lastIdx
                    error("ticker_data_manager:RangeEmpty", ...
                        "지정한 기간에 데이터가 없습니다. start=%s end=%s", string(startDate), string(endDate));
                end

                keep0 = max(1, firstIdx - warmupBars);
                keep1 = lastIdx;
                T1 = T1(keep0:keep1, :);
            end

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

            good = isfinite(this.Open) & isfinite(this.High) & isfinite(this.Low) & isfinite(this.Close) & ...
                   this.Open>0 & this.High>0 & this.Low>0 & this.Close>0;
            this.Date  = this.Date(good);
            this.Open  = this.Open(good);
            this.High  = this.High(good);
            this.Low   = this.Low(good);
            this.Close = this.Close(good);

            % SMAs
            this.smaWeek     = movmean(this.Close, [this.WEEK_N-1 0], "omitnan");
            this.smaFast     = movmean(this.Close, [this.FAST_N-1 0], "omitnan");
            this.smaSlow     = movmean(this.Close, [this.SLOW_N-1 0], "omitnan");
            this.smaLongTerm = movmean(this.Close, [this.LONGTERM_N-1 0], "omitnan");

            % ATR
            this.atr = this.compute_atr(this.ATR_N);

            % Long-term trend
            this.longTermTrend = this.compute_long_term_trend();

            % MACD
            [this.macdLine, this.macdSignal, this.macdHist] = this.compute_macd(this.Close, this.MACD_FAST, this.MACD_SLOW, this.MACD_SIGNAL);
        end

        function n = length(this)
            n = numel(this.Date);
        end

        function ctx = get_ctx_prev(this, t)
            % Hot-path: small struct, fixed fields.
            if t < 3
                ctx = struct(); ctx.valid = false; return;
            end

            ctx = struct( ...
                'valid', true, ...
                'date', this.Date(t), ...
                'close_prev', this.Close(t-1), ...
                'smaWeek_prev', this.smaWeek(t-1), ...
                'smaFast_prev', this.smaFast(t-1), ...
                'smaSlow_prev', this.smaSlow(t-1), ...
                'smaLongTerm_prev', this.smaLongTerm(t-1), ...
                'smaLongTerm_prev2', this.smaLongTerm(t-2), ...
                'atr_prev', this.atr(t-1), ...
                'longTermTrend_prev', this.longTermTrend(t-1), ...
                'macdLine_prev', this.macdLine(t-1), ...
                'macdSignal_prev', this.macdSignal(t-1), ...
                'macdHist_prev', this.macdHist(t-1) ...
            );
        end

        function [d0, d1] = data_range(this)
            d0 = this.Date(1);
            d1 = this.Date(end);
        end

        function idx = indices_in_range(this, startDate, endDate)
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
            H = this.High(:);
            L = this.Low(:);
            C = this.Close(:);

            cp = [NaN; C(1:end-1)];
            tr = max([H-L, abs(H-cp), abs(L-cp)], [], 2);
            atr = movmean(tr, [n-1 0], "omitnan");
        end

        function [macdLine, sigLine, histLine] = compute_macd(~, C, fastN, slowN, sigN)
            C = double(C(:));
            macdLine = nan(size(C));
            sigLine  = nan(size(C));
            histLine = nan(size(C));

            if numel(C) < max([fastN slowN sigN]) || fastN<=0 || slowN<=0 || sigN<=0
                return;
            end

            emaFast = ticker_data_manager.ema(C, fastN);
            emaSlow = ticker_data_manager.ema(C, slowN);
            macdLine = emaFast - emaSlow;

            sigLine  = ticker_data_manager.ema(macdLine, sigN);
            histLine = macdLine - sigLine;
        end

        function T = standardize_columns(~, T)
            T = ticker_data_manager.static_standardize_columns(T);
        end
    end

    methods (Static, Access=private)
        function y = ema(x, N)
            x = double(x(:));
            y = nan(size(x));
            if N <= 0 || isempty(x)
                return;
            end
            alpha = 2 / (N + 1);

            i0 = find(isfinite(x), 1);
            if isempty(i0)
                return;
            end
            y(i0) = x(i0);

            for i = i0+1:numel(x)
                if ~isfinite(x(i))
                    y(i) = y(i-1);
                else
                    y(i) = alpha * x(i) + (1-alpha) * y(i-1);
                end
            end
        end

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

    methods (Static)
        function out = normalize_ticker_6(x)
            % Fast normalize ticker codes to 6-digit string.
            if isnumeric(x)
                xv = x(:);
                good = isfinite(xv);
                xi = round(xv(good));

                [u, ~, ic] = unique(xi); % sorted unique
                uStr = string(compose("%06d", u));

                outv = strings(numel(xv), 1);
                outv(good) = uStr(ic);
                outv(~good) = string(missing);

                out = reshape(outv, size(x));
                return;
            end

            s = string(x);
            s = strtrim(s);

            s2 = regexprep(s, "[^\d]", "");
            emptyMask = (strlength(s2) == 0);
            if any(emptyMask)
                for i = 1:numel(s2)
                    if emptyMask(i)
                        v = str2double(s(i));
                        if isfinite(v)
                            s2(i) = string(sprintf("%06d", round(v)));
                        end
                    end
                end
            end

            out = s2;
            for i = 1:numel(out)
                if strlength(out(i)) == 0
                    continue;
                end
                if strlength(out(i)) < 6
                    out(i) = string(pad(out(i), 6, "left", "0"));
                elseif strlength(out(i)) > 6
                    out(i) = extractAfter(out(i), strlength(out(i)) - 6);
                end
            end
            out = reshape(out, size(s));
        end
    end
end
