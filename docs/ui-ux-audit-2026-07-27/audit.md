# KB Tune current UI/UX audit — 2026-07-27

## Scope

- Current build at `d9c9048`
- Captured states: splash and weekly-plan main screen
- Goal: understand the current week's safe-to-spend amount and take the next corrective action

## Step health

1. Splash — Healthy. Product purpose and demo entry are clear.
2. Weekly plan — Needs refinement. The numbers are richer than the prior design, but the zero-budget state does not tell the user what to do next.
3. Chat, analysis, and products — Not visually audited in this run. Simulator accessibility control was unavailable, so these screens were not used as screenshot evidence.

## Current-screen findings

1. Replace `0원 더 쓸 수 있어요` with a dedicated zero state such as `이번 주 추가 지출 여유가 없어요`. Follow it with one primary action: `조정안 보기`.
2. The weekly hero, rollover calculation card, and payment-due dock expose three different money concepts at once. Label them explicitly as `추가 사용 가능액`, `주차별 예산 이월`, and `다음 결제일 청구 예정액`.
3. The payment-due dock is visually as strong as the hero and covers part of the calculation card. Collapse it to a smaller summary or place it in the scroll flow.
4. The core action, adding or testing a future event, is not visible in the first viewport. Add `일정 넣어보기` near the hero or as a clear floating action.
5. When the safe-to-spend value is zero, highlight which editable event caused the constraint and offer a direct action on that event. Preserve protected events and explain why they were not selected.
6. The calculation card is valuable but begins below the fold and is partially hidden. Show a one-line cause directly beneath the hero, then keep the detailed ledger behind `계산 기준`.

## Development priority

1. Zero/negative-budget recovery flow.
2. One-tap what-if event simulation.
3. Clear separation of available cash, weekly allocation, rollover, and card billing.
4. Current-screen regression screenshots and UI tests for zero, positive, and negative states.

## Evidence limits

- VoiceOver order, Dynamic Type reflow, touch behavior, and the remaining three tabs still require live interaction testing.
