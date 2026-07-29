# Cloud Run 용 이미지.
#
# 이 백엔드는 사용자 데이터를 저장하지 않는다 — 요청에 실려 온 값으로 그때그때 계산하고
# 끝난다. 볼륨도 세션도 없다. 이건 편의가 아니라 "일정 제목은 서버로 안 나간다"는
# 약속의 근거다.
#
# Firestore 를 하나 붙였지만 방향이 반대다. 공개 통계 기준 금액(baseline)을 **읽기만**
# 하고 아무것도 쓰지 않는다. 들어 있는 값은 참가격·가계동향조사·서울 상권분석에서 온
# 공표 통계뿐이라 개인을 가리키는 데이터가 없다. 여기에 사용자 값을 쓰기 시작하면
# 위 문장부터 다시 써야 한다.

FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# 의존성을 먼저 넣어야 코드만 바뀔 때 이 층을 다시 안 만든다.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
# Firestore 를 못 읽을 때 쓰는 기준 금액 사본. 이게 있어야 자격증명이 없거나 DB 가
# 죽어도 추정이 그대로 나온다.
COPY data ./data

# Cloud Run 이 PORT 를 넣어 준다(기본 8080). 그 값에 맞춰 열어야 요청이 들어온다.
ENV PORT=8080

# run.sh 의 원칙을 컨테이너에서도 지킨다 — 루프백이 아닌 주소로 열 때는 인증 키가 있어야 한다.
# 없이 뜨면 주소를 아는 누구나 이 서버를 통해 OpenAI 크레딧을 쓸 수 있다.
CMD ["sh", "-c", "\
if [ -z \"$KB_TUNE_API_KEY\" ]; then \
  echo 'KB_TUNE_API_KEY 가 없습니다. 공개 주소로 뜨는 서버에는 반드시 필요합니다.' >&2; \
  exit 1; \
fi; \
exec uvicorn app.main:app --host 0.0.0.0 --port \"$PORT\""]
