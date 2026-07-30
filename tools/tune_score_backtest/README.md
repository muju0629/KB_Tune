# Tune 점수 롤링 백테스트

카드 결제만 포함한 합성 데이터로 다음 산출물이 정상 생성되는지 확인한다.

- 앞 2개월 → 다음 1개월 롤링 예측
- 목표 달성 확률의 Brier score와 10-bin calibration error
- 안전 버퍼별 결과
- 가장 크게 틀린 사례 1건
- 보호 소비·미승인 실행·근거 누락 가드레일

```bash
python tools/tune_score_backtest/run_backtest.py
```

`results/`의 숫자는 제품 정확도 주장이 아니라 검증 파이프라인의 합성 기준선이다.
