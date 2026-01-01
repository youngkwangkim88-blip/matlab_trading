classdef null_exec_model < handle
    % null_exec_model
    % Provides the minimal interface expected by ticker_trader.step().
    % Used when ticker_trader runs in UseExternalAccounting mode.

    properties
        StartDate datetime = datetime(1900,1,1)
        EndDate   datetime = datetime(2100,12,31)
    end

    methods
        function fee = entryFee(~, ~, ~)
            fee = 0;
        end
        function fee = exitFee(~, ~, ~)
            fee = 0;
        end
        function d = shortBorrowDaily(~)
            d = 0;
        end
    end
end
