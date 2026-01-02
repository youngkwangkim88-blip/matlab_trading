classdef fee_model_rate < handle
    % fee_model_rate
    % Simple proportional costs: commission + slippage as rate of notional.

    properties
        CommissionRate double = 0.0
        SlippageRate double = 0.0
    end

    methods
        function this = fee_model_rate(commissionRate, slippageRate)
            if nargin >= 1 && ~isempty(commissionRate)
                this.CommissionRate = max(0, double(commissionRate));
            end
            if nargin >= 2 && ~isempty(slippageRate)
                this.SlippageRate = max(0, double(slippageRate));
            end
        end

        function fee = trade_fee(this, notionalAbs)
            % notionalAbs: absolute notional value (>=0)
            notionalAbs = max(0, double(notionalAbs));
            rate = max(0, this.CommissionRate) + max(0, this.SlippageRate);
            fee = notionalAbs * rate;
        end
    end
end
