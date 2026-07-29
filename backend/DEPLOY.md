# 배포 — Google Cloud Run

시뮬레이터 시연만 할 거면 배포하지 않아도 된다. `./run.sh` 로 충분하다.
실기기나 심사 제출처럼 **폰이 직접 서버에 닿아야 할 때만** 이 문서를 쓴다.

## 무엇을 올리고 무엇을 안 올리는가

```
Artifact Registry  ──▶  Cloud Run (asia-northeast3)  ──읽기만──▶  Firestore
   이미지 저장소            FastAPI, 요청 없으면 0으로 축소         baseline/current
                              환경변수: OPENAI, KB_TUNE_API_KEY      공개 통계 기준 금액
```

**사용자 데이터를 저장하는 곳은 여전히 없다.** 요청에 실려 온 값으로 계산하고 끝난다.
소비 금액·일정·설정은 폰 안에만 있다.

Firestore 가 하나 붙어 있지만 방향이 반대다. 문서 하나(`baseline/current`)를 **읽기만**
하고 아무것도 쓰지 않는다. 들어 있는 값은 한국소비자원 참가격·국가데이터처 가계동향조사·
서울열린데이터광장 상권분석에서 온 공표 통계뿐이라, 특정 개인을 가리키는 데이터가 없다.
런타임 계정에도 `roles/datastore.viewer`(읽기 전용)만 준다.

여기에 사용자 값을 쓰기 시작하면 App Store 슬라이드와 README의 "일정 제목은 어떤 경우에도
밖으로 안 나가요"부터 다시 써야 한다.

**로드밸런서도 만들지 않는다.** Cloud Run 이 배포와 함께 `https://…run.app` 주소를 준다.
커스텀 도메인이 꼭 필요한 게 아니면 쓸 이유가 없고, 트래픽이 0이어도 시간당 과금된다.

## 준비

Docker 는 필요 없다. `--source` 로 올리면 Cloud Build 가 클라우드에서 이미지를 만든다.

```sh
brew install --cask google-cloud-sdk
gcloud init                      # 계정 로그인 + 프로젝트 선택
gcloud services enable run.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com
```

## 기준 금액 DB (한 번만)

이걸 건너뛰어도 서비스는 뜬다 — 컨테이너 안의 `data/baseline_prices.json` 사본으로
돌아간다. Firestore 는 앱 재배포 없이 값을 갱신하려고 붙인 것이다.

```sh
gcloud services enable firestore.googleapis.com
gcloud firestore databases create --location=asia-northeast3 --type=firestore-native

# 런타임은 읽기만 한다. 쓰기 권한을 주지 않는다.
gcloud projects add-iam-policy-binding kb-tune \
  --member=serviceAccount:<프로젝트번호>-compute@developer.gserviceaccount.com \
  --role=roles/datastore.viewer
```

값 갱신은 분기에 한 번이면 충분하다(원본 통계가 그 주기로 나온다).

```sh
python -m tools.fetch_baseline    # 공개 데이터 → data/baseline_prices.json
python -m tools.seed_baseline     # → Firestore
```

`fetch_baseline` 은 `SEOUL_OPENAPI_KEY`(서울열린데이터광장 무료 발급)와 `openpyxl` 이
필요하다. 둘 다 수집 전용이라 런타임 이미지에는 안 들어간다.

## 배포

`backend/` 에서 실행한다.

```sh
gcloud run deploy kb-tune-api \
  --source . \
  --region asia-northeast3 \
  --allow-unauthenticated \
  --set-env-vars "LLM_BACKEND=openai,OPENAI_MODEL=gpt-5.4" \
  --set-env-vars "OPENAI=<OpenAI 키>" \
  --set-env-vars "KB_TUNE_API_KEY=<아무 긴 무작위 문자열>"
```

`--allow-unauthenticated` 는 "구글 로그인 없이 접근 허용"이라는 뜻이지 무방비가 아니다.
인증은 `KB_TUNE_API_KEY` 로 앱과 서버 사이에서 한다. 이 값이 없으면 컨테이너가 아예 안 뜬다.

키를 명령줄에 남기기 싫으면 Secret Manager 를 쓴다.

```sh
printf '%s' '<OpenAI 키>' | gcloud secrets create openai-key --data-file=-
gcloud run deploy kb-tune-api --source . --region asia-northeast3 \
  --allow-unauthenticated \
  --set-env-vars "LLM_BACKEND=openai,OPENAI_MODEL=gpt-5.4" \
  --set-secrets "OPENAI=openai-key:latest" \
  --set-env-vars "KB_TUNE_API_KEY=<무작위 문자열>"
```

## 앱 연결

주소가 나오면 앱 빌드에 주입한다. 코드가 **https 가 아니면 막는다**(`AgentService.baseURL`).

```sh
xcodebuild ... \
  KB_TUNE_API_BASE_URL=https://kb-tune-api-xxxxx.asia-northeast3.run.app \
  KB_TUNE_API_KEY=<배포에 쓴 것과 같은 값>
```

저장소에 올리지 않는 `.xcconfig` 파일에 두 값을 적어도 된다.

## 확인

```sh
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "X-API-Key: <키>" https://<주소>/api/health          # 200

curl -s -X POST https://<주소>/api/search \
  -H "X-API-Key: <키>" -H "Content-Type: application/json" \
  -d '{"query":"이태원 맛집"}'                              # answer 에 문장이 오면 정상
```

키 없이 부르면 401 이 나와야 한다. 200 이 나오면 `KB_TUNE_API_KEY` 가 안 걸린 것이다.

## 비용

무료 체험 크레딧(₩448,796)은 **90일 한정**이다. 소진되거나 기간이 끝나면 자동 청구가 아니라
서비스가 멈춘다. 이 구성은 요청이 없으면 과금이 없지만, 심사가 끝나면 정리하는 게 낫다.

```sh
gcloud run services delete kb-tune-api --region asia-northeast3
```
