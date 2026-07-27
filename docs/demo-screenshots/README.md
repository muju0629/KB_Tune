# 예산 상태 스크린샷 회귀 기록

기준 기기: iPhone 17 Pro Simulator, iOS 26.5  
기준 날짜: 2026년 7월 22일  
생성 테스트: `KB_TuneUITests`

| 상태 | 파일 | 고정하는 핵심 UI |
| --- | --- | --- |
| 양수 | `budget-positive.png` | 추가 사용 가능액, 단일 `일정 넣어보기` CTA |
| 0원 | `budget-zero.png` | `0원` 바로 아래 `조정안 보기`, 항상 보이는 `일정 넣어보기` |
| 음수 이월 | `budget-negative.png` | 지난주 초과 사용 안내, 조정 CTA, 축소된 카드 청구액 도크 |

UI 테스트는 날짜와 장부 상태를 launch argument로 고정한다. 실행 시점의 날짜나 앞선 테스트의 데이터에 영향을 받지 않는다.

```sh
xcodebuild \
  -project KB_Tune.xcodeproj \
  -scheme KB_Tune \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test \
  -only-testing:KB_TuneUITests/KB_TuneUITests/testBudgetStatePositiveScreenshot \
  -only-testing:KB_TuneUITests/KB_TuneUITests/testBudgetStateZeroScreenshot \
  -only-testing:KB_TuneUITests/KB_TuneUITests/testBudgetStateNegativeScreenshot
```

