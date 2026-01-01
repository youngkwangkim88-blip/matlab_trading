panel = "kospi_top100_ohlc_30y.csv";
sd = datetime(2020,1,1);
ed = datetime(2025,12,31);

% 1) 포트폴리오 마스터 생성
pm = portfolio_master(1e9);

% 2) 종목 DM
dm1 = ticker_data_manager(panel, "005930", sd, ed);

% 3) 종목별 Spec (예: KRX 주식)
spec1 = instrument_spec("005930","Samsung", ...
    "FeeModel", fee_model_rate(0.00015, 0.00010), ...
    "TaxModel", tax_model_krx_stt(0.0018, 0.0015), ...
    "MarginModel", margin_model_simple(0.0, 0.50, 0.30), ...
    "BorrowRateAnnual", 0.0215, ...
    "MaxNotionalFrac", 0.20, ...
    "AllowShort", true);

% 4) 신호 트레이더(기존 ticker_trader 재사용)
tr1 = ticker_trader(dm1, 0, true);

% 5) 유니버스에 추가
pm.add_instrument(dm1, spec1, tr1);

% 6) 엔진 실행
eng = portfolio_backtest_engine(pm);
eng.StartDate = sd;
eng.EndDate   = ed;

eng.run();
%%
eng.plot();
% rep = eng.report()
% 