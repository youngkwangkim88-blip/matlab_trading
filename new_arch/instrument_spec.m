classdef instrument_spec < handle
    % instrument_spec
    % Defines per-instrument trading rules/costs for portfolio backtesting.

    properties
        Symbol string = ""
        Name string = ""
        AssetType string = "UNKNOWN"   % e.g., "KRX_STOCK", "ETF", "BOND", "GOLD"
        Currency string = "KRW"

        Multiplier double = 1.0         % contract multiplier (futures, gold, etc.)
        AllowShort logical = true

        % Position sizing cap relative to current portfolio equity
        % (target notional = MaxNotionalFrac * equity)
        % NOTE: 단일 종목 검증/최적화 단계에서는 기존 엔진과의 비교를 위해
        %       기본값을 1.0(100% 노출)로 둡니다.
        MaxNotionalFrac double = 1.0

        % Cost / tax / margin models (pluggable)
        FeeModel handle = []
        TaxModel handle = []
        MarginModel handle = []

        % Annual borrow rate applied to short notional (simple model)
        % NOTE: 요청 사항에 따라 기본값을 0.04(연 4%)로 둡니다.
        BorrowRateAnnual double = 0.04
    end

    methods
        function this = instrument_spec(symbol, name, varargin)
            if nargin >= 1 && ~isempty(symbol)
                this.Symbol = string(symbol);
            end
            if nargin >= 2 && ~isempty(name)
                this.Name = string(name);
            end

            % Name-value overrides
            if ~isempty(varargin)
                for k = 1:2:numel(varargin)
                    key = string(varargin{k});
                    val = varargin{k+1};
                    if isprop(this, key)
                        this.(key) = val;
                    end
                end
            end

            if isempty(this.FeeModel)
                this.FeeModel = fee_model_rate(0,0);
            end
            if isempty(this.TaxModel)
                this.TaxModel = tax_model_krx_stt(0,0);
            end
            if isempty(this.MarginModel)
                this.MarginModel = margin_model_simple();
            end

            this.MaxNotionalFrac = max(0, double(this.MaxNotionalFrac));
            this.Multiplier = max(realmin, double(this.Multiplier));
        end

        function fee = trade_fee(this, notionalAbs)
            fee = 0;
            if ~isempty(this.FeeModel) && ismethod(this.FeeModel, "trade_fee")
                fee = this.FeeModel.trade_fee(notionalAbs);
            end
        end

        function tax = trade_tax(this, dt, side, notionalAbs)
            tax = 0;
            if ~isempty(this.TaxModel) && ismethod(this.TaxModel, "trade_tax")
                tax = this.TaxModel.trade_tax(dt, side, notionalAbs);
            end
        end

        function m = required_margin(this, qty, price)
            m = 0;
            if ~isempty(this.MarginModel) && ismethod(this.MarginModel, "required_margin")
                m = this.MarginModel.required_margin(qty, price, this.Multiplier);
            end
        end
    end
end
