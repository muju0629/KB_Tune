# Cloud Run 용 이미지.
#
# 이 백엔드는 상태를 저장하지 않는다 — 요청에 실려 온 값으로 그때그때 계산하고 끝난다.
# 그래서 데이터베이스도 볼륨도 없다. 이건 편의가 아니라 "일정 제목은 서버로 안 나간다"는
# 약속의 근거다. 저장할 곳을 만들면 그 문장부터 다시 써야 한다.

FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# 의존성을 먼저 넣어야 코드만 바뀔 때 이 층을 다시 안 만든다.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

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
