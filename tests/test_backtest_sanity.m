classdef test_backtest_sanity < matlab.unittest.TestCase
    % Unit tests to detect accounting/sign/valuation bugs.
    %
    % Run in MATLAB:
    %   addpath(pwd);
    %   addpath(fullfile(pwd,'tests'));
    %   results = runtests('tests');
    %   disp(table(results));

    properties (Constant)
        DataFile = "kospi_top100_ohlc_30y.csv";  % change if needed
        Ticker   = "005930";
        InitCap  = 1000000000;
    end

    methods (Test)
        function test_accounting_identity_close_based(testCase)
            [eng, master] = testCase.make_engine(datetime(2019,1,1), datetime(2024,12,31));
            eng.run();

            tr = master.Traders(1);
            vc = tr.ValCurve;

            testCase.verifyGreaterThan(height(vc), 50, "ValCurve too short; check data window.");

            lhs = vc.EquityClose;
            rhs = vc.Cash + vc.PosValue;
            testCase.verifyLessThan(max(abs(lhs-rhs)), 1e-6, "EquityClose identity violated.");

            testCase.verifyGreaterThanOrEqual(min(vc.Shares), 0, "Shares went negative.");
        end

        function test_buyhold_2025_positive_when_stock_up(testCase)
            [eng, master] = testCase.make_engine(datetime(2025,1,1), datetime(2025,12,31));
            tr = master.Traders(1);
        
            % 강제 Buy&Hold 모드 (구현되어 있다고 가정)
            tr.ForceMode = "BuyHold";
        
            eng.run();
        
            % 1) 데이터/기록이 존재하는지 먼저 확인
            testCase.verifyFalse(isempty(tr.ValCurve), "ValCurve가 비어 있습니다. (해당 기간 데이터가 없거나 record_valuation이 호출되지 않음)");
        
            % 2) 시작/끝 평가가치(종가 기준)
            eq0 = tr.ValCurve.EquityClose(1);
            eq1 = tr.ValCurve.EquityClose(end);
        
            % 3) 2025년에 주가가 올랐다면 Buy&Hold는 양(+)이어야 함
            testCase.verifyGreaterThan(eq1, eq0, "2025 Buy&Hold 결과가 양수가 아닙니다. (평가/부호/체결 정렬 오류 가능)");
        end

        function test_short_roundtrip_profit_when_price_drops(testCase)
            [eng, master] = testCase.make_engine(datetime(2019,1,1), datetime(2019,3,31));
            tr = master.Traders(1);
            tr.set_force_mode("Flat");

            dm = tr.DM;

            % pick a day where next-day open < today open
            t0 = 10;
            found = false;
            for t = 10:min(200, dm.length()-2)
                if dm.Open(t+1) < dm.Open(t)
                    t0 = t;
                    found = true;
                    break;
                end
            end
            testCase.assumeTrue(found, "Could not find a down-move window for this test in your dataset.");

            tr.reset_for_run(testCase.InitCap);

            dt0 = dm.Date(t0);
            dt1 = dm.Date(t0+1);
            o0  = dm.Open(t0);
            o1  = dm.Open(t0+1);
            c0  = dm.Close(t0);
            c1  = dm.Close(t0+1);

            tr.manual_enter(dt0, o0, c0, int8(-1), eng);
            tr.manual_exit(dt1, o1, c1, eng);

            TL = tr.TradeLog;
            realized = TL.RealizedPnL(end);
            testCase.verifyGreaterThan(realized, 0, "Short realized PnL not positive despite price drop; sign inversion suspected.");
        end
    end

    methods (Access=private)
        function [eng, master] = make_engine(testCase, startDate, endDate)
            if ~isfile(testCase.DataFile)
                error("TestDataMissing:File", "Data file '%s' not found. Put it in the current folder or edit test_backtest_sanity.DataFile.", testCase.DataFile);
            end

            dm = ticker_data_manager(testCase.DataFile, testCase.Ticker);
            master = trader_master(testCase.InitCap);
            master.add_trader(dm, true);

            eng = backtest_engine(master);
            eng.set_simulation_window(startDate, endDate);
        end
    end
end
