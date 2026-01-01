classdef portfolio_master < handle
    % portfolio_master
    % Holds instruments (data + signal traders) and a shared portfolio_account.

    properties
        InitialCapital double = 1e9
        Portfolio portfolio_account

        Instruments struct = struct([])   % array of struct('Symbol',...)
        SpecMap containers.Map            % symbol->instrument_spec
    end

    methods
        function this = portfolio_master(initialCapital)
            if nargin >= 1 && ~isempty(initialCapital)
                this.InitialCapital = double(initialCapital);
            end
            this.Portfolio = portfolio_account(this.InitialCapital);
            this.SpecMap = containers.Map('KeyType','char','ValueType','any');
        end

        function add_instrument(this, dm, spec, tr)
            % add_instrument(dm, spec, tr)
            % dm   : ticker_data_manager
            % spec : instrument_spec
            % tr   : ticker_trader (optional). If omitted, a new ticker_trader is created.

            if nargin < 2 || isempty(dm) || ~isa(dm,'ticker_data_manager')
                error("portfolio_master:add_instrument","dm must be a ticker_data_manager");
            end
            if nargin < 3 || isempty(spec) || ~isa(spec,'instrument_spec')
                error("portfolio_master:add_instrument","spec must be an instrument_spec");
            end
            if nargin < 4 || isempty(tr)
                tr = ticker_trader(dm, 0, spec.AllowShort);
            end
            if ~isa(tr,'ticker_trader')
                error("portfolio_master:add_instrument","tr must be a ticker_trader");
            end

            % External accounting mode (optional): if trader supports it, enable.
            if ismethod(tr, 'enable_external_accounting')
                tr.enable_external_accounting(true);
            end
            if ismethod(tr, 'set_logging')
                tr.set_logging(false, true, true);
            end

            symbol = string(spec.Symbol);
            if strlength(symbol) == 0
                symbol = string(dm.Ticker);
                spec.Symbol = symbol;
            end
            key = char(symbol);

            this.SpecMap(key) = spec;

            rec = struct();
            rec.Symbol = symbol;
            rec.DM = dm;
            rec.Trader = tr;
            rec.Spec = spec;

            if isempty(this.Instruments)
                this.Instruments = rec;
            else
                this.Instruments(end+1) = rec; %#ok<AGROW>
            end
        end

        function reset(this)
            this.Portfolio = portfolio_account(this.InitialCapital);
        end
    end
end
