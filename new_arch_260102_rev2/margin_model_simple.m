classdef margin_model_simple < handle
    % margin_model_simple
    % Minimal margin model.
    % - Long: no margin by default
    % - Short: reserves a fraction of short notional as margin

    properties
        LongMarginRate double = 0.0
        ShortInitRate double = 0.50
        ShortMaintRate double = 0.30
    end

    methods
        function this = margin_model_simple(longRate, shortInit, shortMaint)
            if nargin >= 1 && ~isempty(longRate)
                this.LongMarginRate = max(0, double(longRate));
            end
            if nargin >= 2 && ~isempty(shortInit)
                this.ShortInitRate = max(0, double(shortInit));
            end
            if nargin >= 3 && ~isempty(shortMaint)
                this.ShortMaintRate = max(0, double(shortMaint));
            end
        end

        function m = required_margin(this, qty, price, multiplier)
            qty = double(qty);
            price = double(price);
            multiplier = double(multiplier);
            if ~isfinite(qty) || ~isfinite(price) || ~isfinite(multiplier)
                m = 0; return;
            end
            notionalAbs = abs(qty * price * multiplier);
            if qty >= 0
                m = notionalAbs * max(0, this.LongMarginRate);
            else
                m = notionalAbs * max(0, this.ShortInitRate);
            end
        end
    end
end
