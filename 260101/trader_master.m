classdef trader_master < handle
    % trader_master
    % - Creates ticker_trader instances
    % - Allocates initial capital across tickers
    % - Future extension: reallocation logic

    properties
        InitialCapital double = 1e9  % 10억 기본 (원하시면 10e9로 바꾸세요)
        Traders ticker_trader = ticker_trader.empty()
        Tickers string = string.empty()
    end

    methods
        function this = trader_master(initialCapital)
            if nargin>0
                this.InitialCapital = initialCapital;
            end
        end

        function add_trader(this, dm, enableShort)
            % Add a ticker_trader (nargin-based for compatibility)
            if nargin < 2 || isempty(dm)
                error("trader_master:add_trader","dm is required.");
            end
            if nargin < 3 || isempty(enableShort)
                enableShort = true;
            end
            if ~isa(dm, 'ticker_data_manager')
                error("trader_master:add_trader","dm must be a ticker_data_manager.");
            end
            enableShort = logical(enableShort);

this.Tickers(end+1) = dm.Ticker;
            % equity는 allocate_initial에서 배정
            tr = ticker_trader(dm, 0, enableShort);
            this.Traders(end+1) = tr;
        end

        function allocate_initial_equal(this)
            n = numel(this.Traders);
            if n==0
                error("trader_master:NoTraders","트레이더가 없습니다.");
            end
        
            each = this.InitialCapital / n;
            for i=1:n
                this.Traders(i).reset_for_run(each);  % ✅ equity+로그+곡선 모두 초기화
            end
        end


        function eq = total_equity(this)
            eq = 0;
            for i=1:numel(this.Traders)
                eq = eq +  this.Traders(i).get_equity();
            end
        end
    end
end
