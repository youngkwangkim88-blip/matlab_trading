eng.run();

% 1) 포트폴리오 체결 로그가 쌓였는지
height(pm.Portfolio.TradeLog)

% 2) 포트폴리오 보유 수량이 0이 아닌지
pm.Portfolio.get_position("005930").Qty

% 3) EquityCurve가 실제로 움직이는지 (앞/뒤 몇 줄)
pm.Portfolio.EquityCurve(1:5,:)
pm.Portfolio.EquityCurve(end-5:end,:)
