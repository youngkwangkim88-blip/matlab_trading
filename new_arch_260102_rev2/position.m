classdef position < handle
    % position
    % Keeps average-price position and realized PnL (simple).

    properties
        Symbol string = ""
        Qty double = 0.0
        AvgPrice double = NaN
        RealizedPnL double = 0.0
    end

    methods
        function this = position(symbol)
            if nargin >= 1 && ~isempty(symbol)
                this.Symbol = string(symbol);
            end
        end

        function [newQty, newAvg, realizedDelta] = simulate_after_trade(this, qtyDelta, price)
            % Simulate update without mutating the object.
            qtyDelta = double(qtyDelta);
            price = double(price);

            oldQty = double(this.Qty);
            oldAvg = double(this.AvgPrice);
            realizedDelta = 0.0;

            if oldQty == 0
                newQty = qtyDelta;
                if newQty == 0
                    newAvg = NaN;
                else
                    newAvg = price;
                end
                return;
            end

            newQty = oldQty + qtyDelta;

            % Same direction add
            if sign(oldQty) == sign(newQty) && sign(qtyDelta) == sign(oldQty)
                newAvg = (abs(oldQty)*oldAvg + abs(qtyDelta)*price) / max(realmin, abs(newQty));
                return;
            end

            % Reduction or reversal -> realize on the closed portion
            closedQty = min(abs(qtyDelta), abs(oldQty));
            realizedDelta = closedQty * (price - oldAvg) * sign(oldQty);

            if newQty == 0
                newAvg = NaN;
            elseif sign(newQty) == sign(oldQty)
                % reduced but still same side -> avg unchanged
                newAvg = oldAvg;
            else
                % reversed: remaining opens at trade price
                newAvg = price;
            end
        end

        function apply_trade(this, qtyDelta, price)
            [newQty, newAvg, realizedDelta] = this.simulate_after_trade(qtyDelta, price);
            this.Qty = newQty;
            this.AvgPrice = newAvg;
            this.RealizedPnL = this.RealizedPnL + realizedDelta;
        end

        function v = notional(this, price, multiplier)
            if nargin < 2 || isempty(price), price = this.AvgPrice; end
            if nargin < 3 || isempty(multiplier), multiplier = 1.0; end
            v = double(this.Qty) * double(price) * double(multiplier);
        end
    end
end
