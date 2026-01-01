% run_oop_demo.m (panel CSV version)
clear; clc;

panelCsv = "kospi_top100_ohlc_30y.csv";  % 가정 파일명

% 원하는 티커(삼성전자, SK하이닉스)
% tickers = ["005930","000660"];
tickers = ["005930"];


% (옵션) 파일 안에 어떤 티커가 있는지 확인
% allTickers = ticker_data_manager.list_tickers(panelCsv);
% disp(allTickers(1:min(end,20)));

% 데이터 매니저 생성
% dm1 = ticker_data_manager(panelCsv, tickers(1));
startDate = datetime(2020,1,1);
endDate =datetime(2021,1,31); 
dm1 = ticker_data_manager(panelCsv, tickers(1), startDate, endDate);
% dm2 = ticker_data_manager(panelCsv, tickers(2));

% 마스터/엔진 구성
master = trader_master(1e9); % 10억
master.add_trader(dm1, true);
% master.add_trader(dm2, true);
master.allocate_initial_equal();

eng = backtest_engine(master);

% 하이퍼 파라미터 세팅
eng.Commission = 0.00015;
eng.Slippage   = 0.00010;
eng.STT_2024   = 0.0018;
eng.STT_2025   = 0.0015;
eng.ShortBorrowAnnual = 0.0215;
%%
bestOn.SpreadEnterPct=0.003;
bestOn.SpreadExitPct=0.001
bestOn.UseATRFilter=false
bestOn.AtrEnterK=0.5;
bestOn.AtrExitK=0.05;
bestOn.ConfirmDays=3;
bestOn.MinHoldDays=1;
bestOn.CooldownDays=0;
bestOn.UseLongTrendFilter=false;
bestOn.UseShortTrendFilter=false;
bestOn.EnableShort=true;
bestOn.LongDailyStop=0.03;
bestOn.LongTrailStop=0.1;
bestOn.ShortDailyStop=0.02;
bestOn.ShortTrailStop=0.1;
bestOn.UseMACDRegimeFilter=false;
bestOn.UseMACDExit=false;
bestOn.MACDSignalMode="hist";
bestOn.UseMACDSizeScaling=false;
bestOn.MACDSizeMin=0.25;
bestOn.MACDSizeMax=1;
bestOn.MACDSizeAtrK=0.25
master.Traders(1).set_hparams(bestOn);


%%
% 시뮬레이션 기간 세팅
eng.set_simulation_window(startDate, endDate);
% 실행
eng.run();

% 리포트/저장/플롯
rep = eng.report();
disp(rep);

eng.save_excel("oop_backtest_report.xlsx");
eng.plot();
