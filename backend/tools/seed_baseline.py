"""baseline_prices.json → Firestore 적재.

    python -m tools.seed_baseline            # 올림
    python -m tools.seed_baseline --dry-run  # 무엇이 올라갈지만 출력

컬렉션 하나에 문서 하나(`baseline/current`)다. 표가 20KB도 안 되고 통째로 읽어
앱에 내려주기 때문에 문서를 쪼갤 이유가 없다. 분기마다 fetch_baseline 을 돌리고
이걸 다시 실행하면 덮어쓴다.

이 컬렉션에는 공개 통계만 들어간다. 사용자 데이터는 어떤 경우에도 여기 쓰지 않는다.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "data" / "baseline_prices.json"
PROJECT = "kb-tune"
COLLECTION = "baseline"
DOCUMENT = "current"


def _credentials():
    """ADC 가 있으면 그걸, 없으면 gcloud 로그인 토큰을 쓴다.

    서비스 계정 키 파일을 만들지 않으려는 것이다. 키 파일은 한번 새면 취소 전까지
    계속 유효하지만 gcloud 토큰은 한 시간이면 만료된다. Cloud Run 위에서는 둘 다
    필요 없다 — 런타임은 서비스 계정으로 자동 인증된다.
    """
    import google.auth
    from google.auth.exceptions import DefaultCredentialsError

    try:
        creds, _ = google.auth.default()
        return creds
    except DefaultCredentialsError:
        pass

    from google.oauth2.credentials import Credentials
    token = subprocess.run(["gcloud", "auth", "print-access-token"],
                           capture_output=True, text=True, check=True).stdout.strip()
    return Credentials(token=token)


def main() -> int:
    payload = json.loads(DATA.read_text(encoding="utf-8"))
    summary = (f"version={payload['version']} · 일정 {len(payload['events'])}종 "
               f"· 품목 {len(payload['items'])}종 "
               f"· 비목 {len(payload['monthly']['bimok'])}종")

    if "--dry-run" in sys.argv:
        print(f"{PROJECT}/{COLLECTION}/{DOCUMENT} ← {summary}")
        return 0

    from google.cloud import firestore

    client = firestore.Client(project=PROJECT, credentials=_credentials())
    client.collection(COLLECTION).document(DOCUMENT).set(payload)
    print(f"올렸다 — {PROJECT}/{COLLECTION}/{DOCUMENT} · {summary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
