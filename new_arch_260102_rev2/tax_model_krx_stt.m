classdef tax_model_krx_stt < handle
    % tax_model_krx_stt
    % Korean Securities Transaction Tax (STT) model (simple).
    % Applies to SELL trades only.

    properties
        Rate2024 double = 0.0
        Rate2025 double = 0.0
        RateDefault double = 0.0
    end

    methods
        function this = tax_model_krx_stt(rate2024, rate2025, rateDefault)
            if nargin >= 1 && ~isempty(rate2024)
                this.Rate2024 = max(0, double(rate2024));
            end
            if nargin >= 2 && ~isempty(rate2025)
                this.Rate2025 = max(0, double(rate2025));
            end
            if nargin >= 3 && ~isempty(rateDefault)
                this.RateDefault = max(0, double(rateDefault));
            else
                this.RateDefault = this.Rate2025;
            end
        end

        function tax = trade_tax(this, dt, side, notionalAbs)
            % dt: datetime
            % side: "BUY" or "SELL" (string/char)
            % notionalAbs: absolute notional (>=0)
            notionalAbs = max(0, double(notionalAbs));
            side = upper(string(side));

            if side ~= "SELL"
                tax = 0;
                return;
            end

            y = year(dt);
            if y == 2024
                r = this.Rate2024;
            elseif y == 2025
                r = this.Rate2025;
            else
                r = this.RateDefault;
            end

            tax = notionalAbs * max(0, r);
        end
    end
end
