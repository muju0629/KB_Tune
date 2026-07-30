<div align="center">
    
# KB Tune

### AI, 가계부, 캘린더 기능을 한번에
<br/>

<img src="https://img.shields.io/badge/KB_AI_Challenge-2026-FFCC00?style=flat-square&labelColor=25241F" alt="KB AI Challenge 2026" />
<img src="https://img.shields.io/badge/iOS-26.5-FFCC00?style=flat-square&labelColor=25241F&logo=apple&logoColor=white" alt="iOS 26.5" />
<img src="https://img.shields.io/badge/Swift-SwiftUI-FFCC00?style=flat-square&labelColor=25241F&logo=swift&logoColor=white" alt="Swift SwiftUI" />
<img src="https://img.shields.io/badge/EventKit-Calendar-FFCC00?style=flat-square&labelColor=25241F&logo=apple&logoColor=white" alt="EventKit" />
<img src="https://img.shields.io/badge/On--Device-Vision_Speech_NL-FFCC00?style=flat-square&labelColor=25241F&logo=apple&logoColor=white" alt="On-device Vision, Speech, NaturalLanguage" />
<img src="https://img.shields.io/badge/Swift_Testing-XCTest-FFCC00?style=flat-square&labelColor=25241F&logo=swift&logoColor=white" alt="Swift Testing" />
<img src="https://img.shields.io/badge/FastAPI-Python-FFCC00?style=flat-square&labelColor=25241F&logo=fastapi&logoColor=white" alt="FastAPI Python" />
<img src="https://img.shields.io/badge/LLM-OpenAI-FFCC00?style=flat-square&labelColor=25241F&logo=openai&logoColor=white" alt="OpenAI" />
<img src="https://img.shields.io/badge/Python-3.12-FFCC00?style=flat-square&labelColor=25241F&logo=python&logoColor=white" alt="Python 3.12" />
<img src="https://img.shields.io/badge/Pydantic-v2-FFCC00?style=flat-square&labelColor=25241F&logo=pydantic&logoColor=white" alt="Pydantic v2" />
<img src="https://img.shields.io/badge/Google_Cloud-Run-FFCC00?style=flat-square&labelColor=25241F&logo=googlecloud&logoColor=white" alt="Google Cloud Run" />
<img src="https://img.shields.io/badge/Firestore-read__only-FFCC00?style=flat-square&labelColor=25241F&logo=firebase&logoColor=white" alt="Firestore read-only" />
<img src="https://img.shields.io/badge/Docker-Cloud_Build-FFCC00?style=flat-square&labelColor=25241F&logo=docker&logoColor=white" alt="Docker" />

<br/><br/>

<img src="docs/header.png" width="820" alt="KB Tune — 가계부는 이미 쓴 돈만 보여줍니다. KB Tune은 앞으로 쓸 돈을 미리 알려드립니다." />

<img src="docs/appstore/01-intro.png" width="190" alt="가계부, 캘린더, AI가 만나다" />
<img src="docs/appstore/02-chat.png" width="190" alt="대화로 일정 추가" />
<img src="docs/appstore/03-forecast.png" width="190" alt="예상 지출" />
<img src="docs/appstore/04-basis.png" width="190" alt="계산 근거" />

<sub>이번 주 예산 · 대화로 일정 추가 · 예상 지출 · 계산 근거</sub>

<br/><br/>

<img src="docs/appstore/05-ask.png" width="190" alt="언제든 물어보기" />
<img src="docs/appstore/06-analysis.png" width="190" alt="소비 분석" />
<img src="docs/appstore/07-products.png" width="190" alt="카드·적금" />
<img src="docs/appstore/08-privacy.png" width="190" alt="안 나가는 것" />

<sub>언제든 물어보기 · 소비 분석 · 카드·적금 · 안 나가는 것</sub>

</div>

<br/>

일정에 "카페"라고만 적어도 금액이 채워져요. 예전에 카페에서 쓰신 돈에서 가져오거든요.
<br/>그 자리에서 이번 주에 더 써도 되는 돈이 다시 계산돼요. 저축 목표와 지난주에 남긴 돈까지 넣어서요.
<br/>목표가 위태로워 보이면 미리 말씀드려요. 뭘 미루면 되는지까지요.

<br/>

<table>
<tr>
<td width="50%" valign="top">

**📖 &nbsp;[사용 안내](#user-guide)**

앱이 뭘 하는지, 어떻게 쓰는지

- [왜 만들었나요](#why)
- [처음 켜면](#getting-started)
- [화면 4개](#screens)
- [대화로 할 수 있는 일](#chat)
- [내 정보는 어디까지 나가나요](#privacy)
- [돈을 세 가지로 나눠요](#money-states)
- [Tune 점수와 선제 경보](#tune-score)
- [자주 묻는 질문](#faq)

</td>
<td width="50%" valign="top">

**💻 &nbsp;[개발자용 문서](#dev-docs)**

어떻게 계산하고 어떻게 만들었는지

- [핵심 루프](#core-loop)
- [대화는 이렇게 동작해요](#chat-flow)
- [알고리즘](#algorithms)
- [모델 선정과 검증](#model-selection)
- [설계 원칙](#principles)
- [공공 가이드라인과의 관계](#guideline)
- [보안 설계](docs/security.md)
- [기술 스택](#stack)
- [파일 구조](#structure)
- [실행](#run)

</td>
</tr>
</table>

<br/>

---

<a id="user-guide"></a>

# 📖 사용 안내

<a id="why"></a>

## 🤔 왜 만들었나요?

> *"통장에 15만원 남았는데... 다음주 약속 나가면 얼마 남지?*
> *병원도 가야 하고, 옷도 사야 하는데..."*

머릿속으로 계산하면 잘 안 맞아요. 그러다 보면 저축은 늘 뒤로 밀려요.

가계부 앱들은 "식비 30만원"처럼 **덩어리로** 예산을 잡으라고 해요.
근데 우리는 식비로 사는 게 아니라, **약속 하나 병원 한 번**으로 돈을 써요.

그래서 KB Tune은 일정마다 금액을 붙여요.

```diff
- 식비 30만원          ← 얼마 남았는지 모르겠어요
+ 이번 주 40,000원 나가고, 60,000원 남아요
```

## 🤝 세 가지는 꼭 지켜요

**금액을 그냥 바꾸지 않아요**
왜 그 금액인지 항상 같이 알려드려요.

> 💬 성제님의 미용실(와드) 주기는 6주 정도였어요.
> 5월 16일 42,000원 · 6월 27일 38,000원

**줄이라고 하지 않아요**
"이건 포기 못 해"라고 고르신 건 건드리지 않아요. 아낄 곳은 나머지에서 찾아요.

**카드부터 팔지 않아요**
카드·적금은 계획을 다 세운 다음에 나와요. 돈이 어떻게 도는지부터 보여드려요.

<br/>

<a id="getting-started"></a>

## 🚀 처음 켜면

|  | 이걸 하면 | 이렇게 돼요 |
|:--:|---|---|
| 1️⃣ | **동의서 읽고 고르기** | 세 가지를 따로 여쭤봐요. 원문을 접지 않고 그대로 펼쳐서 보여드려요<br/>필수 하나만 누르면 시작할 수 있고, 나머지 둘은 안 눌러도 다 돌아가요 |
| 2️⃣ | **캘린더 연결하고 몇 개만 답하기** | 한 달 수입, 모으고 싶은 금액, 포기 못 하는 소비를 고르시면 끝이에요<br/>포기 못 한다고 고른 건 나중에도 안 건드려요 |
| 3️⃣ | **앱 열기** | 큰 숫자 하나가 먼저 보여요. 이번 주에 더 써도 되는 금액이에요<br/>월세·통신비·저축·이미 잡힌 약속을 다 빼고 남은 돈이에요 |
| 4️⃣ | **일정 하나 넣어보기** | 제목만 적어도 금액이 자동으로 채워져요<br/>넣기 전에 *"이거 넣으면 얼마 남는지"*부터 보여드려요 |
| 5️⃣ | **Tune 점수 눌러보기** | 이번 계획이 저축 목표·안전 잔액·보호 소비를 함께 지키는지 봐요<br/>점수가 낮으면 추천안과 제외한 이유를 같이 보여줘요 |
| 6️⃣ | **주말에 분석 탭 보기** | 어디에 얼마 썼는지, 앞으로 얼마 나갈지 한눈에 보여요 |

> 동의를 캘린더 연결보다 **먼저** 여쭤봐요. 뒤에 두면 제목을 이미 읽은 뒤에 묻는 셈이 되니까요.

<br/>

<a id="screens"></a>

## 📱 화면 4개

| 탭 | 여기서 뭘 하나요 |
|---|---|
| 🗓️ **주간** | 이번 주에 얼마 더 쓸 수 있는지와 Tune 점수를 봐요<br/>점수를 누르면 조정안·제외 이유·계산 근거가 열려요 |
| 💬 **대화** | 말로 물어보고 말로 바꿔요<br/>*"이번 달 카페에 얼마 썼어?"* · *"8월 5일 카페 갈래"* · *"일정 하나 미뤄줘"* |
| 📊 **분석** | 어디에 얼마나 쓰는지 봐요<br/>이미 쓴 돈과 앞으로 나갈 돈을 색으로 나눠서 보여드려요 |
| 💳 **카드·적금** | 내 소비에 맞는 카드를 찾아요<br/>얼마나 이득인지 계산해서 순서대로 보여드려요 |

설정은 주간 화면 오른쪽 위 동그라미를 누르면 나와요.
탭은 좌우로 밀어도 넘어가요. 주간 탭에서 **주간을 한 번 더 누르면** 맨 위로 올라가요.


<br/>

<a id="chat"></a>

## 💬 대화로 할 수 있는 일

보통 금융 앱 챗봇은 물어보면 "고객센터로 연결해 드릴까요?"라고 해요.
KB Tune은 **묻는 것도, 바꾸는 것도** 대화 안에서 끝나요.

### 뭘 물어볼 수 있나요

**1. 이미 쓴 돈**

```
나  이번 달 카페에 얼마 썼어?

☁️  카페는 오늘까지 20,000원 썼어요.
    7/3에 12,000원, 7/11에 8,000원 쓴 합계예요.
```

합계를 미리 만들어두고 답하는 게 아니에요. 그때그때 더해서 답해요.
그래서 "외식이랑 카페 중에 뭐가 더 많아?" 같은 것도 답할 수 있어요.

**2. 앞으로 써도 되는지**

```
나  오늘 7만원짜리 바지 사도 될까?

☁️  이번 주는 62,000원까지가 여유예요. 7만원이면 8,000원 넘어가요.

    금요일 약속을 다음 주로 미루면 52,000원이 돌아와서 괜찮아져요.

    [ 다음 주로 옮기기 ]  [ 그냥 살래요 ]
```

**3. 말로 일정 넣기**

```
나  8월 5일 카페 갈래

☁️  8월 5일 카페 약속, 넣어도 괜찮아요.
    기기에 저장된 카페 결제 2건의 중앙값 20,000원이에요.
    관측 범위는 10,000원~30,000원이에요.

    8/5이 든 주 추가 사용 가능액 314,896원 → 294,896원

    [ 일정 추가 ]  [ 금액 변경 ]  [ 안 넣을래요 ]
```

날짜(`8월 5일`)와 종류(`카페`)를 폰에서 알아들어요.
금액은 **내 과거 카페 결제**에서 가져와요. 평균이 아니라 중앙값을 써요 —
한 번 크게 쓴 게 있으면 평균이 확 올라가거든요.

### 말한 대로 바뀌어요

말풍선 안의 버튼을 누르면 진짜로 일정이 들어가고, 예산 숫자가 바로 움직여요.
기기 캘린더에도 같이 저장돼요.

| 버튼 | 누르면 |
|---|---|
| **일정 추가** | 캘린더에 들어가고, 이번 주 남은 금액이 그만큼 줄어요 |
| **다음 주로 옮기기** | 일정이 옮겨지고, 이번 주 금액이 돌아와요 |
| **금액 변경** | 제안한 금액을 직접 고칠 수 있어요 |
| **카드 보러 가기** | 내 소비에 맞는 카드 화면으로 넘어가요 |

### 숫자를 지어내지 않아요

이게 제일 중요해요. 금융 앱에서 AI가 숫자를 틀리면 안 되니까요.

**금액은 AI가 만들지 않아요.** 앱이 계산한 숫자만 AI에게 주고, AI는 그걸로 문장만 써요.
준 숫자끼리 더하거나 비교하는 건 되지만, 없는 숫자를 만들면 잡혀요.

```
✅  12,000원 + 8,000원 = 20,000원   ← 준 숫자로 계산
✅  118,500원을 "약 12만원"으로      ← 반올림
❌  125,000원                        ← 어디에도 없는 숫자
```

걸리면 그 숫자 옆에만 **(확인 필요)** 를 붙여요. 답 전체를 지우지 않아요.
틀린 숫자 하나 때문에 맞는 문장 세 개까지 사라지면 손해잖아요.
다만 세 개 넘게 틀리면 그냥 앱이 만든 문장으로 바꿔요.

### 길게 말하지 않아요

얼마 썼는지 물으면 한두 문장이면 끝이에요.
써도 되냐고 물을 때만 이유랑 방법을 붙여요.

말투도 손봤어요. 예전엔 이렇게 답했거든요.

```diff
- 이유는 이번 주 추가 사용 가능액이 62,000원이고, 이번 달 남은 예산은
- 204,000원이지만 앞으로 잡힌 일정 예상액이 801,000원이라 카페 예산을
- 넉넉하게 보기 어려워서예요.  (이런 문단이 4개)

+ 카페는 오늘까지 20,000원 썼어요. 7/3에 12,000원, 7/11에 8,000원 쓴 합계예요.
```

"이유는", "영향은", "행동 제안은"으로 문장을 시작하지 못하게 막았어요.
그렇게 쓰면 대화가 아니라 서류처럼 읽히거든요.

### 오프라인 상태 지원 

서버가 안 되면 폰 안에서 답해요. 대신 미리 준비한 답변만 나와요.
**중요한 건 그때도 숫자는 똑같다는 거예요.** 화면에 62,000원이 떠 있으면 대화도 62,000원이라고 해요.

### 음성인식도 지원

마이크를 누르고 말하면 돼요. 음성 인식은 폰 안에서만 해요.
녹음 파일은 저장하지 않고, 애플 서버로도 안 보내요.

<br/>

<a id="privacy"></a>

## 🔒 제 정보는 어디까지 나가나요?

**기본 설정에서는 유출 걱정 할 필요는 없어요.** 앱을 받아서 그냥 켜면 외부 AI를 한 번도 부르지 않아요.
예산 계산·일정 추가·금액 예측은 전부 폰 안에서 끝나요.

다만 **자유롭게 대화하려면 AI 모델이 필요해요.** 외부 AI 없이도 앱은 돌아가지만,
외부 검색이 필요하거나 조금 더 어려운 질문에 대한 대답을 받고 싶으면 켜야해요.

켜면 아래와 같이 나가요.

| | 나가나요? |
|---|---|
| 이름 | **안 나가요** — 서버에 받는 칸 자체를 안 만들었어요 |
| 나이대 | **안 나가요** — 폰에만 두고, 기준 금액에 배수를 곱할 때만 써요 (안 골라도 돼요) |
| 내가 쓴 질문 그대로 | **안 나가요** — 폰에서 `카페 지출 질문` 같은 형태로 바꿔서 보내요 |
| 웹 검색을 켰을 때 보낸 문장 | 켜면 그 문장 그대로 나가요 — 아래 설명을 봐주세요 |
| **저장된 일정 제목** | **안 나가요** — 폰에서 `[모임 일정]`처럼 바꿔서 보내요 |
| 방금 말한 새 일정 이름 | "AI 기능"을 켜면 나가요 (기본은 꺼짐) |
| 영수증 캡처 · 거기서 읽은 글자 | **안 나가요** — 폰 안에서 읽어요 |
| 음성 | **안 나가요** — 폰 안에서만 인식해요 |
| 날짜 · 유형 · 금액, 예산 숫자 | 켜면 나가요 |

### 그래서 저희는 동의는 세 가지를 따로 여쭤봐요

처음 켤 때 고지 원문을 **접지 않고 그대로 펼쳐서** 보여드리고, 항목마다 따로 누르게 해요.
"전체 동의" 버튼 하나로 뭉뚱그리지 않아요.

| 항목 | 안 누르시면 |
|---|---|
| **[필수]** 개인정보 수집·이용 <sub>제15조</sub> | 시작 버튼이 안 눌려요<br/>날짜·금액으로 예산을 계산하는 데 꼭 필요한 것만이에요 |
| [선택] 민감정보 <sub>제23조</sub> | **일정 제목을 아예 안 읽어요.** 소비 유형만 직접 고르시면 돼요 |
| [선택] 국외 이전 <sub>제28조의8</sub> | 답변을 기기 안 엔진이 만들어요<br/>받는 자·국가·항목·기간·거부권을 원문에 다 적어뒀어요 |

**선택 두 개는 안 누르셔도 앱의 모든 기능이 돌아가요.** 설정에서 언제든 끄고 켤 수 있고,
동의서 전문도 다시 보실 수 있어요.

"AI 기능" 스위치가 곧 국외 이전 동의예요. 두 값이 어긋나면 *철회했는데도 계속 나가는* 사고가
되니까, 켜고 끄는 길을 하나로 묶어뒀어요. 끄면 그 순간부터 전송이 멈춰요.

### 제목은 가리는 게 아니라 안 읽어요

민감정보에 동의하지 않으시면, 캘린더에서 일정을 가져올 때 **제목 칸을 아예 안 읽어요.**
앱 안에서도 그냥 `일정`이에요. 나중에 가리는 게 아니라 처음부터 안 들이는 거예요.

가려서 보내는 방식보다 강해요. 가리는 건 규칙이 하나 놓치면 새는데, **안 읽으면 놓칠 게 없거든요.**

여행처럼 공개 통계에도 내 이력에도 없는 일정이 있어요. 켜면 웹에서 찾아보는데,
**검색어는 앱이 코드에 적힌 말로만 새로 만들어요.** 제목의 낱말은 하나도 안 실려요.

```diff
  일정 제목    제주도 3박4일 여행
- 이렇게 안 보내요   "제주도 3박4일 여행 경비"
+ 이렇게 보내요     "국내 3박 여행 1인 평균 경비"
```

읽는 건 일정 유형(`여행`), `3박` 같은 숫자, 해외인지 아닌지 셋뿐이에요.
`제주도`는 어디에도 안 남아요. 지명을 지우는 방식이 아니라 **코드에 없는 말은
나갈 방법이 없는** 방식이라, 지명 사전에서 하나 빠뜨려도 새지 않아요.

**이미 저장된 일정 제목은 어떤 경우에도 안 나가요.** 폰에서 `[모임 일정]`처럼 바꾼 뒤에 보내요.
제목에는 `"정형외과 진료"`, `"성당 모임"` 같은 게 들어가거든요. 건강이나 종교는 금액보다 민감해요.

**"AI 기능"을 켜면 딱 하나가 더 나가요** — 방금 친 문장 속 새 일정 이름이요.
대화로 *"제주도 여행 8월 14일에 넣어줘"*라고 하려면 AI가 그 말을 알아들어야 하니까요.
그래도 이름·연락처·주소·계좌번호, 그리고 이미 저장된 다른 일정 제목은 여전히 가려서 보내요.

끄면 기기 안의 예산·패턴 엔진만 써요. 일정은 주간 화면에서 바꾸시면 돼요.

### 웹 검색만 예외예요

`"이태원 맛집"`을 검색하려면 그 말이 그대로 나가야 해요. 장소를 지우면 검색할 게 남지 않으니까요.
그래서 검색은 다른 것과 따로 뒀어요.

- **켤 때만 나가요.** 대화 입력줄 왼쪽 돋보기를 눌러야 켜지고, 다시 누르면 꺼져요.
  켜져 있는 동안에는 위쪽 배지가 `검색 사용 중`으로 바뀌어서 지금 어느 쪽인지 늘 보여요.
- **나가는 건 그 문장 하나예요.** 일정도 예산도 카드 내역도 검색으로는 안 보내요.
  서버가 받는 칸에 그 필드들을 아예 안 만들어 뒀어요.
- **검색으로 받은 답은 대화에 남아요.** 뒤이어 "그럼 그 여행 예산 잡아줘"처럼 이어서 물어볼 수 있게요.
  그 답이 다음 대화에 문맥으로 실려 나가는데, 이건 웹에서 온 공개 정보예요.

> [!NOTE]
> **나중에는 이것도 안 나가게 하려고요.**
> 지금은 외부 AI를 쓰지만, KB가 자체 모델을 운영하면 그쪽으로 바꿔 끼울 수 있게 만들어 뒀어요.
> 그러면 대화 기능을 그대로 쓰면서도 데이터가 KB 밖으로 나가지 않아요.

**나간 뒤에는 어떻게 되나요?** OpenAI API 데이터는 기본적으로 모델 학습에 사용되지 않지만,
보관기간은 호출한 API와 조직의 데이터 제어 계약에 따라 달라요. 기본 abuse monitoring 로그는
통상 최대 30일 보관될 수 있고, Responses API의 application state는 설정에 따라 30일 이상
남을 수 있습니다. Zero Data Retention도 자동 적용이 아니라 별도 승인·요건이 필요한 옵션이에요.
그래서 KB Tune은 계약이 확정되기 전까지 “30일 안에 전부 삭제”나 “무조건 무보존”을 약속하지 않습니다.
현재 기준은 [OpenAI API 데이터 제어 공식 문서](https://developers.openai.com/api/docs/guides/your-data#data-retention-controls-for-abuse-monitoring)에서 확인할 수 있어요.

더 알고 싶으시면 **[보안 설계](docs/security.md)**를 봐주세요. 아직 못 막은 것도 적어뒀어요.

<br/>

<a id="money-states"></a>

## 🎨 돈을 세 가지로 나눠요

"이번 달 80만원"이라고만 하면, 이미 쓴 건지 앞으로 쓸 건지 알 수 없잖아요.
그래서 세 가지로 나눠서 보여드려요.

| 상태 | 뜻 | 화면에서 |
|---|---|---|
| 🟡 **확정 지출** | 이미 썼거나 반드시 나갈 돈 | 분석에서 **노란색** |
| 🕐 **예약 예산** | 일정에 잡아뒀지만 아직 결제 전 | **예약** 배지 |
| ⬛ **패턴 예상** | 캘린더엔 없지만 주기가 돌아온 지출 | 분석에서 **짙은 회색** |

> [!IMPORTANT]
> **예약은 실제 출금이 아니에요.**
> 계좌에서 돈이 나가지 않아요. 쓸 수 있는 금액에서만 빠져요.
>
> *"8월 2일 데이트 비용으로 100,000원을 8월 계획 예산에 예약할까요? 실제 출금은 없어요."*

<br/>

<a id="tune-score"></a>

## 🎚️ Tune 점수와 선제 경보

이번 주 사용 가능액 아래에 **Tune 점수**가 있어요. 단순히 돈이 많이 남았는지만 보지 않고,
저축 목표를 이어갈 수 있는지, 위험 구간의 잔액이 안전한지, 사용자가 지켜두기로 한 소비를
건드리지 않아도 되는지를 함께 봐요.

```
Tune 점수 72점 · 데이터 신뢰도 보통

추천     팀 외식 다음 주로 이동       72 → 84점
보조안   쇼핑 금액 줄이기             72 → 78점
제외     친구 모임 취소               보호 소비로 지정
제외     적금 자동이체 취소           장기 목표 훼손
```

거래 변화와 예정 일정, 카드 결제일이 겹쳐 점수가 크게 떨어지면 앱이 먼저 알려드려요.
다만 일정이나 적금을 **자동으로 바꾸지는 않아요.** 추천안과 제외한 이유를 확인하고
사용자가 승인했을 때만 계획을 다시 계산해요. 판단과 승인 기록은 앱을 다시 켜도 남아요.

> [!NOTE]
> Tune 점수의 현재 가중치는 제품 정책 v0예요. 실제 고객의 행동 개선을 증명한 인과 점수가 아닙니다.
> 점수와 별도로 `데이터 신뢰도 낮음·보통·높음`을 항상 보여줘요.

<br/>

## 🔮 예상 소비

캘린더에 없어도 때 되면 나가는 돈이 있잖아요. 그런 건 미리 알려드려요.

```
🛒 쿠팡 장보기          7/23 즈음   예상 35,000원

   성제님의 쿠팡 장보기 주기는 10일 정도였어요.
   6월 23일 34,000원 · 7월 3일 36,000원 · 7월 13일 35,000원

   [ 계획에 넣기 ]   [ 이번엔 안 써요 ]
```

> [!NOTE]
> **이 금액은 예산에서 미리 빼지 않아요.**
> "계획에 넣기"를 누르셔야 반영돼요. 모르는 사이에 남은 돈이 줄면 안 되니까요.

<br/>

<a id="faq"></a>

## ❓ 자주 묻는 질문

<details>
<summary><b>예약하면 돈이 빠져나가나요?</b></summary>
<br/>

아니에요. 계좌는 그대로예요. "쓸 수 있는 금액"에서만 빠져요.

</details>

<details>
<summary><b>예상 소비는 왜 남은 돈에서 안 빠지나요?</b></summary>
<br/>

확정이 아니라서요. "계획에 넣기"를 누르셔야 들어가요.

</details>

<details>
<summary><b>일정을 취소하면 돈이 돌아오나요?</b></summary>
<br/>

지금은 "다음 주로 옮기기"로 이번 주 부담을 덜 수 있어요.
환불 확정분만 회수하는 기능은 다음에 만들어요.

</details>

<details>
<summary><b>"예상"이 붙은 금액은 뭔가요?</b></summary>
<br/>

아직 확실하지 않은 금액이에요. 확실한 금액에는 "예상"을 안 붙여요.
그래서 "예상"이 없으면 그 숫자는 믿으셔도 돼요.

</details>

<details>
<summary><b>Tune 점수는 제 신용점수인가요?</b></summary>
<br/>

아니에요. 신용평가나 대출 심사에 쓰는 점수가 아닙니다. 현재 계획에서 저축 목표,
안전 잔액, 보호 소비를 함께 지킬 수 있는지를 0~100으로 표시한 앱 안의 계획 점수예요.
점수와 데이터 신뢰도를 따로 보여주고, 낮아도 앱이 금융 행동을 자동 실행하지 않아요.

</details>

<details>
<summary><b>인터넷 없어도 되나요?</b></summary>
<br/>

네. 예산 계산, 일정 추가, 금액 예측은 전부 폰 안에서 해요.
서버가 꺼져 있어도 앱은 똑같이 돌아가요. 대화만 미리 짜둔 답변으로 바뀌어요.

</details>

<details>
<summary><b>제 일정 제목이 서버로 넘어가나요?</b></summary>
<br/>

**민감정보에 동의하지 않으셨다면 애초에 안 읽어요.** 캘린더에서 가져올 때 제목 칸을
건너뛰어서, 앱 안에서도 그냥 `일정`이에요. 나갈 제목 자체가 없는 거예요.

**동의하셨더라도 저장된 제목은 안 나가요.** 폰에서 `[모임 일정]`처럼 바꾼 뒤에 보내요.
평소에는 `8월 5일 · 카페 · 20,000원`처럼 날짜랑 유형이랑 금액만 나가요.

**설정에서 "AI 기능"을 켜면** 방금 친 문장 속 새 일정 이름 하나가 더 나가요.
대화로 일정을 넣고 고치려면 AI가 그 말을 알아들어야 하거든요. 기본은 꺼져 있어요.

켜도 이름·연락처·주소·계좌번호와 저장된 다른 일정 제목은 계속 가려서 보내고,
**검색 엔진에는 앱이 만든 문장만** 가요 — `국내 3박 여행 1인 평균 경비`처럼요.
AI가 검색어에 `제주도` 같은 말을 넣으면 서버가 검사해서 막아요.

</details>

<details>
<summary><b>이제 막 깔았는데, 금액은 어디서 나온 거예요?</b></summary>
<br/>

공개 통계에서 가져와요. 지어낸 숫자가 아니에요.

한국소비자원 참가격(외식 1인분 단가·미용 요금), 국가데이터처 가계동향조사(1인가구 월평균 지출),
서울열린데이터광장 상권분석(업종·연령대별 카드 결제 건당 금액) 세 곳이에요.

금액 옆에 **어디서 온 값인지 항상 같이 적어드려요.**
쓰다 보면 실제로 쓴 금액이 쌓이는데, 그때부터는 통계 대신 그 값을 써요.

</details>

<details>
<summary><b>AI가 숫자를 틀리게 말하면요?</b></summary>
<br/>

금액은 AI가 만드는 게 아니라 앱이 계산해요. AI는 그 숫자로 문장만 써요.
혹시 앱이 안 준 숫자를 말하면 그 숫자 옆에 **(확인 필요)** 가 붙어요.
너무 많이 틀리면 아예 앱이 만든 문장으로 바꿔서 보여드려요.

</details>

<details>
<summary><b>카드 추천이 광고인가요?</b></summary>
<br/>

아니요. 내 소비에 그 카드를 쓰면 한 달에 얼마 이득인지 계산해서 순서를 매겨요.
연회비도 빼고 계산해요. 이득이 없으면 없다고 말해요.

</details>

<br/>

---
---

<a id="dev-docs"></a>

# 💻 개발자용 문서

<a id="core-loop"></a>

## 🔁 핵심 루프

```mermaid
flowchart LR
  A[일정 추가] --> B[이력 → 공개 통계 → 웹검색<br/>순서로 금액 추정]
  B --> C[사용 가능액·Tune 점수<br/>전후 영향 계산]
  C --> D{위험 기준을<br/>넘었나?}
  D -->|예| E[추천·보조·제외안과<br/>근거 제시]
  D -->|아니오| F[일정 확정]
  E --> G{사용자 승인}
  G -->|승인| F
  G -->|거절| H[다시 추천하지 않도록 기록]
  F --> I[캘린더·예산·점수<br/>다시 계산]
  I --> J[판단 근거·모델 버전·<br/>승인 결과 감사 로그]
```

화면에 보이는 숫자가 진짜로 움직여요. 일정을 넣으면 큰 숫자가 내려가고,
Tune 점수와 목표 달성 가능성도 함께 바뀌어요. 위험 기준을 넘으면 그 일정에 경고가 붙어요.
"다음 주로 옮기기"를 누르면 일정이 옮겨지고 이번 주 금액이 돌아와요.

<br/>

<a id="chat-flow"></a>

## 💬 대화는 이렇게 동작해요

```mermaid
flowchart TD
  A["사용자 질문"] --> B["폰에서 의도로 바꿈<br/>원문·이름·제목 제거"]
  B --> C{"백엔드 켜짐?"}
  C -->|아니오| T["폰 안 규칙 답변"]
  C -->|예| D["엔진이 숫자 계산<br/>PlanResult"]
  D --> E["프롬프트에 데이터 블록<br/>계획·카드·앞일정·지난소비"]
  E --> F["LLM 응답 (버퍼링)"]
  F --> G{"숫자가 데이터에서<br/>나온 건가?"}
  G -->|전부 맞음| H["그대로 전송"]
  G -->|1~2개 틀림| I["그 숫자에만<br/>(확인 필요)"]
  G -->|3개 이상 틀림| T
  T --> J["화면 표시"]
  H --> J
  I --> J
```

**토큰을 흘려보내지 않고 서버에서 모았다가 검사해요.** 스트리밍으로 바로 내보내면
마지막 토큰에서 허위 금액이 나와도 되돌릴 수 없거든요. 검사를 통과한 뒤에만 화면에 실어요.

허용 숫자는 이렇게 만들어요 (`allowed_chat_numbers`).

| 넣는 값 | 왜 |
|---|---|
| 엔진이 만든 숫자 (`grounded_numbers`) | 계획의 근거 |
| 앱 화면 숫자 (`app_numbers`) | 화면이 62,000원인데 챗봇이 다른 말 하면 안 됨 |
| 카드 청구액·결제일 | 월 예산엔 안 들어가지만 조언엔 필수 |
| 일정별 금액·날짜 | "그 약속 얼마였지?" |
| **유형별 합계·전체 합계** | 우리가 시킨 덧셈 결과가 '지어낸 숫자'로 걸리면 안 됨 |
| **위 값들의 반올림** | "약 12만원"을 허용하되 125,000원은 막으려고 |

반올림은 허용 오차를 넓히는 대신 **반올림한 값 자체를 명단에 넣어요.**
오차를 5,000원으로 잡으면 542,630원이 허용됐다는 이유로 545,000원까지 통과하거든요.

<br/>

<a id="algorithms"></a>

## 🧮 알고리즘

<a id="model-selection"></a>

### 모델 선정과 검증

KB Tune은 한 모델이 금액·날짜·위험·개인화를 전부 맡지 않아요. 같은 오차라도
`얼마를 틀렸는가`, `발생을 놓쳤는가`, `예산 부족을 과소평가했는가`의 비용이 다르기 때문에
역할별 모델과 지표를 분리했습니다.

| 제품 질문 | 최종 후보 | 선택 근거 | 현재 상태 |
|---|---|---|---|
| 다음 주에 **얼마** 쓸까 | 편향 보정 LightGBM 중앙값 | 점예측 WAPE와 편향의 절충 | 합성 홀드아웃 통과 · 온디바이스 통합 |
| 부족하지 않으려면 **얼마를 잡아둘까** | LightGBM q75 | 과소예측 비용 2·3배에서 최저 손실 | 합성 홀드아웃 통과 · 온디바이스 통합 |
| 다음 7일에 **발생할까** | 일정형은 Hazard + 캘린더, 그 외 Hazard | Brier 0.1089, 주간 LightGBM보다 개선 | 합성 홀드아웃 통과 · 온디바이스 통합 |
| **언제** 발생할까 | 일정형은 Hazard + 캘린더, 그 외 Hazard | 일정형 날짜 MAE 0.69일 → 0.44일 | 합성 홀드아웃 통과 · 온디바이스 통합 |
| 오래 쓰면 **자동 개인화될까** | Bayesian 충분통계량 shadow mode | 신규 홀드아웃에서 미질문 일반화 미확인 | 사용자 비노출 |
| 지금 계획이 **안전할까** | 결정론 Tune 점수 + 보호 제약 | 근거 추적·승인·감사 로그 단위 테스트 | 앱 구현 완료 |

> [!IMPORTANT]
> 아래 수치는 대부분 합성 데이터의 상대 비교예요. 실제 고객 성능이나 인과효과가 아닙니다.
> 실험마다 생성 시드·평가 기간·분모가 다르므로 **같은 표 안의 값끼리만** 직접 비교해야 합니다.

선정 모델은 `forecast-synth-v1-2026-07-30` 버전의 2.4MB 중립 JSON 트리로 번들됩니다.
Swift 런타임이 서버 호출 없이 중앙값·q75·발생확률·예상일을 계산하며, Python이 만든
고정 입력과 Swift 결과를 골든 테스트로 대조합니다. 앱은 모델·피처 버전을 Tune 상세와
감사 로그에 남깁니다. 모델 파일에는 트리·집단 사전값·보정 계수만 있고 원거래·사용자 ID는 없습니다.

#### 1) 중앙 금액: LightGBM + 별도 사용자 편향 보정

발생 여부와 발생했을 때의 금액을 나눠 학습한 뒤 다시 결합합니다. 전역 비선형 기준 모델은
[LightGBM](#ref-lightgbm)을 사용했습니다.

$$
\hat y_{raw}(x)
= \hat p(\text{발생}\mid x)\;\mathrm{expm1}\!\left(\hat m_{\log}(x)\right)
$$

학습에 쓰지 않은 보정 사용자 집합 $\mathcal C$에서 총액 비율을 구해 구조적 과소편향을 줄입니다.

$$
c=\mathrm{clip}\left(
\frac{\sum_{i\in\mathcal C} y_i}
     {\sum_{i\in\mathcal C}\hat y_{raw,i}},
0.75,1.35\right),
\qquad
\hat y_{center}=c\hat y_{raw}
$$

신규 홀드아웃 300명의 8~12주 결과에서 기존 LightGBM의 WAPE는 0.4192,
편향은 −14.2%였습니다. 편향 보정 뒤 WAPE는 **0.4151**, 편향은 **−2.7%**로 줄었습니다.
Ridge는 WAPE 0.4504, 편향 −4.5%로 안정적 비교 기준선이지만 최종 중앙값 정확도는
보정 LightGBM이 더 좋았습니다.

#### 2) 안전 금액: q75 분위 회귀

예산 앱에서는 실제 지출보다 적게 예측하는 것이 더 위험해요. 과소예측 비용을 $k$,
과대예측 비용을 1로 두면 다음 손실을 사용합니다.

$$
L_k(y,\hat y)=k(y-\hat y)_+ +(\hat y-y)_+
$$

이 손실의 최적 분위수는 $\tau=k/(k+1)$입니다. 과소예측 비용을 3배로 두면
$\tau=3/4=0.75$이므로 q75를 사용합니다. LightGBM은 pinball loss를 최소화해
이 분위수를 직접 학습합니다. 이 선택은 평균이 아니라 조건부 분위수를 추정하는
[분위 회귀](#ref-quantile-regression)에 기반합니다.

$$
\rho_\tau(u)=u\left(\tau-\mathbf 1[u<0]\right),
\qquad
\hat q_\tau(x)=\arg\min_q\sum_i\rho_\tau(y_i-q(x_i))
$$

| 과소예측 비용 | 최저 손실 모델 | 손실 ↓ |
|---:|---|---:|
| 2배 | q75 | 0.6164 |
| 3배 | q75 | 0.7604 |
| 5배 | q83 | 0.9485 |

q75의 WAPE는 0.4723, 편향은 +18.4%로 중앙 예측에는 너무 보수적입니다. 대신
과소예측 사용자 비율을 54.5%에서 **29.7%**로 낮춰 현금부족 위험과 Tune 점수의
안전 입력으로 사용합니다. 화면의 `예상 지출`과 `안전 예상액`을 같은 숫자로 표시하지 않습니다.

<img src="tools/forecast_bench/results/calibrated_risk_conformal_holdout/figures/02_expected_vs_safe.png" width="820" alt="기존 LightGBM, 편향 보정 중앙값, 안전 q75의 편향과 과소예측률 비교" />

#### 3) 발생일·주기: 일별 discrete-time Hazard

각 날짜 $d\in\{0,\ldots,6\}$에 대해 그날까지 발생하지 않았다는 조건에서 오늘 발생할 확률을 예측합니다.
주간 발생 여부와 날짜 분포를 함께 다루기 위해 [이산시간 생존모형](#ref-discrete-survival)의
hazard 표현을 사용했습니다.

$$
h_d=P(T=d\mid T\ge d, x_d)
$$

하루별 hazard를 주간 발생확률과 날짜 확률질량으로 바꿉니다.

$$
P(T\le6)=1-\prod_{d=0}^{6}(1-h_d),
\qquad
P(T=d)=\left[\prod_{j<d}(1-h_j)\right]h_d
$$

예상 결제일은 $P(T=d)$가 가장 큰 날짜입니다. 주기는 마지막 관측 결제일부터 그 날짜까지의
간격으로 계산합니다. 캘린더를 동의한 사용자는 `오늘 일정`, `±1일 일정`, `이번 주 일정 수`만
known-future feature로 추가하고 제목 원문은 모델 입력으로 쓰지 않습니다.

학습 240명, 확률 보정 60명, 신규 평가 100명 × 3개 시드의 12주 결과입니다.

| 모델 | Brier ↓ | PR-AUC ↑ | ECE ↓ | 날짜 MAE ↓ | ±1일 적중률 ↑ |
|---|---:|---:|---:|---:|---:|
| 주기 기준선 | 0.1564 | 0.7628 | 0.0251 | 1.89일 | 49.9% |
| 주간 LightGBM | 0.1278 | 0.8233 | **0.0108** | 1.89일 | 49.9% |
| 일별 Hazard | 0.1244 | 0.8346 | 0.0108 | 1.69일 | **58.6%** |
| **Hazard + 캘린더** | **0.1089** | **0.8622** | 0.0133 | **1.64일** | 58.5% |

확률 자체의 오차는 [Brier score](#ref-brier), 희소한 발생 사건의 순위 품질은
[PR-AUC](#ref-pr-curve), 확률과 실제 빈도의 일치는 ECE로 나눠 확인했습니다.

캘린더 효과는 일정형 소비에 집중됐습니다. 모임·데이트의 날짜 MAE는 0.69일에서
**0.44일**로 줄었지만, 비일정형은 1.91일로 사실상 같았습니다. 따라서 캘린더를
모든 소비에 억지로 적용하지 않습니다.

<img src="tools/forecast_bench/results/hazard_calendar_holdout_12week/figures/03_calendar_ablation.png" width="820" alt="일정형과 비일정형 소비에서 캘린더 특징 유무에 따른 날짜 MAE 비교" />

#### 4) 온디바이스 Bayesian: 설명·구간·shadow mode

현재 Swift `SpendModel`은 사용자×카테고리마다 원거래 대신 충분통계량만 저장합니다.

$$
N(\Delta)\sim\mathrm{Poisson}(\lambda\Delta),
\quad \lambda\sim\mathrm{Gamma}(a,b)
$$

$$
\log X\sim\mathcal N(\mu,\sigma^2),
\quad \mu\sim\mathcal N(\mu_0,\tau^2)
$$

$$
T\sim\mathrm{Weibull}(k,\eta),
\quad \eta=\frac{1}{\lambda\Gamma(1+1/k)}
$$

이 구조는 서버 전송 없이 덧셈 몇 번으로 갱신할 수 있고, 발생확률·금액 구간·설명 근거를
만들기 쉽습니다. 주기 분포에는 양의 시간 간격을 유연하게 표현하는
[Weibull 분포](#ref-weibull)를 사용했습니다. 그러나 장기 개인화 성능은 별개 문제였습니다.

- 안정적인 개인 선호를 강하게 가정한 초기 통제 실험: 1→8주 개인화 WAPE **42.6% 개선**
- 생활변화·피드백 잡음·미질문 평가를 포함한 12주 실험: 8주 **−2.13%p**, 12주 **+0.43%p**
- 개발/최종 시드를 분리한 Ridge + Bayesian: 8주 **−0.19%p**, 12주 **−0.77%p**

최종 신뢰구간이 0을 넘지 않았으므로 “오래 쓸수록 자동으로 계속 좋아진다”고 주장하지 않습니다.
Bayesian 상태는 패턴 설명과 구간 생성에 사용하되, 누적 잔차 개인화는 실제 12주 파일럿 전까지
사용자에게 노출하지 않는 shadow mode로 둡니다.

#### 5) Tune 점수: 예측값을 사용자 결정으로 바꾸는 정책 엔진

Tune 점수는 모델 정확도 점수가 아니라, 현재 계획이 목표·잔액·보호 소비를 함께 지키는 정도입니다.
코드의 v0 가중치는 다음과 같습니다.

$$
\text{Tune}=\mathrm{round}(0.55G+0.30L+0.15V)
$$

$$
G=100\cdot\mathrm{clip}(p_{goal},0,1)
$$

신뢰도가 낮으면 같은 잔액에도 더 큰 안전 버퍼를 요구합니다.

$$
B_{eff}=B_{base}\times
\begin{cases}
1.50,& \text{낮음}\\
1.25,& \text{보통}\\
1.00,& \text{높음}
\end{cases},
\qquad
L=100\cdot\mathrm{clip}\left(\frac{\text{예상 잔액}}{B_{eff}},0,1\right)
$$

필요 조정액 $A=\max(0,B_{eff}-\text{예상 잔액})$ 중 유연 소비로 해결하지 못하는 금액을
$S=\max(0,A-\text{유연 소비})$라고 두면 보호 소비 보존도는 다음과 같습니다.

$$
V=\begin{cases}
100,& \text{보호 소비가 없거나 }S=0\\
100\cdot\mathrm{clip}\left(1-\frac{S}{\text{보호 소비}},0,1\right),& \text{그 외}
\end{cases}
$$

신뢰도는 관측 8주 이상·캘린더 근거율 80% 이상이면 `높음`, 4주·50% 이상이면 `보통`,
그 외에는 `낮음`입니다. 이 임계값과 55:30:15 가중치는 인과적으로 검증된 계수가 아니라
현재 제품 정책 v0이며, 12주 파일럿에서 사용자 선택과 현금부족 결과로 다시 보정해야 합니다.

#### 모델을 고른 과정

동일한 8주 데이터에서 회귀 모델을 먼저 비교했습니다.

| 모델 | 8주 WAPE ↓ | 편향 | 결론 |
|---|---:|---:|---|
| LightGBM | **0.3798** | −6.96% | 점예측 1위, 편향 보정 필요 |
| Ridge | 0.3863 | **−0.15%** | 안정적 기준선 |
| Random Forest | 0.3921 | +0.59% | 두 후보보다 낮음 |
| LightGBM + Bayesian Hybrid | 0.3939 | −5.95% | LightGBM 편향을 물려받음 |
| Renewal Bayesian | 0.3993 | −0.22% | 점예측 우위 없음 |
| 최근 평균 + 캘린더 | 0.4861 | +22.61% | 기준선 |

<img src="tools/forecast_bench/results/model_comparison_8week/figures/01_model_ranking_8week.png" width="820" alt="동일 데이터에서 8주 금액 예측 모델 WAPE 비교" />

최신 기법이라는 이유만으로 채택하지도 않았습니다. [Chronos-2](#ref-chronos2) + 캘린더는 WAPE 0.4351로
LightGBM보다 14.6% 나빴고, 120M 파라미터 서버 모델을 증류할 성능 상한도 확인되지 않았습니다.
개인 안전 게이트와 넓은 conformal 금액 구간도 각각 홀드아웃 개선과 실용적 폭을 통과하지 못해 보류했습니다.
정적 데이터의 [Conformalized Quantile Regression](#ref-cqr)과 분포 변화에 대응하는
[Adaptive Conformal Inference](#ref-adaptive-conformal)는 이후 실제 파일럿에서 다시 검토할 후보입니다.

실험 설계, 신뢰구간, 실패 사례와 전체 재현 경로는
**[소비 예측 실험 종합 정리](docs/tune-experiments-2026-07-30.md)**에서 확인할 수 있습니다.

### 추가 사용 가능액 · `WeekLedger` + `AppModel.weeklyBudget`

```
월 배분 가능액 = 월 수입 − 고정비 − 저축 목표 − 다음 달 할부 이월
주차 기본 배분 = 월 배분 가능액 × (그 주가 이번 달에 포함한 날짜 수 ÷ 월 일수)
주차 실제 배분 = 주차 기본 배분 + 지난주 이월
추가 사용 가능액 = max(0, max(0, 주차 실제 배분) × 방향계수 − 이번 주 일정비)
다음 주 이월 = 주차 실제 배분 − 이번 주 일정비
```

달 첫 주와 마지막 주는 며칠 안 되니까 그만큼만 나눠줘요.
나누다 남은 1~2원은 마지막 주에 몰아서 월 총액이 안 틀어지게 해요.
지난주에 더 썼으면 그 마이너스도 그대로 넘겨요. 안 그러면 초과분이 그냥 사라지거든요.

| 방향 | 주간 계수 | 일정 밖 소액 계수 |
|---|:--:|:--:|
| 🔵 줄이기 | `0.86` | `0.60` |
| ⚪ 유지 | `1.00` | `1.00` |
| 🟠 늘리기 | `1.18` | `1.35` |

### 목표 달성 확률 · `BudgetEngine.probability`

남은 확정 일정과 캘린더 밖 소액지출을 합친 남은 지출 평균부터 구합니다.

$$
\mu=\sum_j a_j
+7{,}500\times d_{left}\times f_{direction}
$$

불확실성은 더 이상 고정 $\sigma=100{,}000$원을 쓰지 않습니다. 일정이 많고 월말까지
기간이 길수록 넓어지도록 확정 일정의 금액 오차와 캘린더 밖 지출의 발생률 오차를 합칩니다.

$$
\sigma^2=
\sum_j a_j^2\left(e^{s^2}-1\right)
+E[X]^2\left(t e^{s^2}+t^2CV_\lambda^2\right)
$$

현재 $s=0.40$, 캘린더 밖 발생률은 일 1건, $CV_\lambda=1.0$을 사용합니다.
남은 예산 $R$에서 목표 달성 확률은 다음과 같습니다.

$$
p_{goal}=\min\left(0.97,\Phi\left(\frac{R-\mu}{\sigma}\right)\right)
$$

iOS는 정규 CDF를 닫힌 형태로 계산하고 백엔드는 같은 평균·분산으로 20,000회 몬테카를로를
돌립니다. 두 구현은 테스트에서 ±1%p 안에 들어와야 합니다. 97% 상한은 모델이 담지 못한
갑작스러운 대형 결제를 무시하고 “확실하다”고 말하지 않기 위한 제한입니다.

### 반복 소비 패턴 · `SpendHistory` + `SpendModel`

같은 이름이 2번 이상 나오면 "반복되는 소비"로 봐요.
몇 일마다 쓰는지, 얼마나 규칙적인지, 보통 얼마 쓰는지를 계산해요.

```
규칙성 = clamp(1 − (주기 편차 ÷ 평균 주기) ÷ 0.5,  0,  1)
```

주기가 들쭉날쭉하지 않을수록 1에 가까워요.
규칙적인 소비는 금액보다 **"몇 주마다 쓰시더라"**를 근거로 말해요.

| 패턴 | 주기 | 평균 금액 | 규칙성 |
|---|---|---:|---:|
| 와드 | 42일 (6주) | 40,000원 | `1.00` |
| 쿠팡 장보기 | 10일 | 35,000원 | `0.93` |
| 주말 데이트 | 14일 (2주) | 70,000원 | `1.00` |
| 미용실 | 49일 (7주) | 26,000원 | `1.00` |
| 카페 | 표본 2건 | 중앙값 20,000원 | 표본 수·관측 범위 표시 |

`SpendModel`은 Gamma–Poisson 발생률, log-normal 금액, Weibull 간격을 사용해
발생확률과 80% 구간을 만들어요. 다만 이 온디바이스 Bayesian 상태가 장기적으로
다른 소비까지 자동 개선한다는 효과는 신규 홀드아웃에서 확인되지 않았습니다.
그래서 현재는 패턴 카드의 설명·구간과 shadow-mode 검증에만 사용하고,
Tune 점수의 검증된 정확도처럼 표현하지 않습니다.

### 이력이 없는 사람의 금액 · `BaselinePrices`

앱을 처음 켠 사람은 과거 소비 이력이 없어요. 그래도 금액은 나와야 하죠.
그렇다고 아무 숫자나 넣을 수는 없어서, **공개 통계에서 가져와요.**

금액을 고르는 순서는 "이 사람에게 얼마나 가까운가"예요.

```
1. 이 사람이 같은 일정에 실제로 쓴 금액        ← 가장 정확
2. 이 사람의 같은 카테고리 결제 이력 2건 이상   ← 중앙값
3. 공개 통계 기준 금액                        ← 이력이 없으면 여기
4. 웹 검색                                   ← 켰을 때만. 여행처럼 통계에 없는 것
5. 규칙에 박아 둔 최후 기본값
```

3번에 쓰는 출처는 세 곳이고, 행마다 출처와 기준 시점이 붙어 화면에 그대로 인용돼요.

| 출처 | 무엇을 | 갱신 |
|---|---|---|
| 한국소비자원 참가격 | 외식 1인분 단가 8품목, 미용·목욕·세탁 요금 (전국 16개 시도) | 매월 |
| 국가데이터처 가계동향조사 | 1인가구 12대 비목 월평균 소비지출 | 분기 |
| 서울열린데이터광장 상권분석 | 업종·연령대별 카드 결제 **건당** 금액 (서울 25개 자치구) | 분기 |

> 💬 호프·간이주점 카드 결제 1건 평균을 기준으로 잡았어요.
> 20대는 같은 업종에서 평균의 0.81배를 써서 그만큼 반영했어요.
> 출처는 서울열린데이터광장 상권분석 카드매출 (2026-1/4, 서울 25개 자치구).

**나이대는 선택 입력이에요.** 온보딩에서 안 골라도 전 연령 평균으로 계산돼요.
고르면 그 나이대의 결제 배수를 곱해요 — 같은 업종이라도 20대와 50대가 꽤 다르거든요.
이 값은 기기에만 있고 서버로 안 보내요.

**축의금과 스터디비는 기준값이 없어요.** 대응하는 공표 통계가 없거든요.
예식장 대관료나 서적 결제액은 그 일정에 쓰는 돈과 다른 행동이라, 억지로 갖다 붙이지 않았어요.

같은 이유로 **학원 수강료(32만원)나 헬스 회원권(19만원)도 안 넣었어요.**
한 번 긁고 몇 달 쓰는 돈이라, "학원 가기"라는 일정에 붙이면 크게 틀리거든요.
결제 한 번이 방문 한 번인 업종만 넣었어요.

**여행은 숙박 1박만 잡아요.** 교통·식비는 며칠인지 몇 명인지에 따라 몇 배씩 달라져서,
공개 통계로 "여행 한 건"을 통째로 맞히는 건 불가능해요. 그래서 여행은
웹 검색(위 4번)을 켜면 그쪽으로 넘어가요.

표는 **통째로 받아서 기기에 두고, 조회도 기기 안에서** 해요.
제목마다 서버에 물어보는 방식이면 일정 제목이 밖으로 나가니까요.

### 일정 태깅

일정 하나에 꼬리표를 두 개 붙여요.

- **결제 업종** — 무엇에 썼나 (외식·카페·교통…)
- **생활 목적** — 왜 썼나 (데이트·공부·모임…)

스타벅스에서 긁었다는 것만으로는 데이트였는지 공부였는지 모르잖아요.
분석 화면은 이 둘을 합쳐서 꼭 필요한 지출과 아닌 걸로 나눠요.

<br/>

<a id="principles"></a>

## 📐 설계 원칙

**숫자는 코드가, 문장은 LLM이**
추가 사용 가능액·달성 확률·혜택 계산은 결정론 엔진(`BudgetEngine`, `RecoEngine`, `SpendHistory`)이 해요.
LLM은 **우리가 준 데이터 안에서만** 말해요. 준 값을 더하거나 비교하는 건 되지만,
없는 값을 만들어내는 건 안 돼요. `app/eval/groundedness.py`가 그 경계를 지켜요.

```
허용   12,000원 + 8,000원 = 20,000원   ← 준 데이터로 계산
허용   118,500원을 "약 12만원"으로     ← 반올림
차단   125,000원                       ← 어디에도 없는 값
```

근거 없는 숫자를 찾으면 **그 숫자에만 `(확인 필요)` 표시**를 붙여요.
답변 전체를 버리면 맞는 문장까지 같이 사라지니까요.
다만 셋 이상이면 답변 대부분이 지어낸 것이므로 결정론 템플릿으로 바꿔요.
표시를 붙였든 바꿨든 **평가 점수에는 모델 실패로 그대로 집계**해요 —
안전 폴백과 모델 품질을 같은 100%로 포장하지 않으려고요.

**서버가 없어도 돌아가요**
`BudgetEngine`은 백엔드 `app/engine`을 Swift로 똑같이 옮긴 거예요.
서버가 꺼져 있어도 같은 숫자가 나와요. 서버는 문장을 더 자연스럽게 만들 뿐이에요.

**될 것처럼 말하지 않아요**
신용카드는 "발급됩니다"가 아니라 "심사를 받아야 해요"라고 해요.
신청 기간이 끝난 상품에 "가입할 수 있어요"를 붙이지 않아요.
카드 실적 채우려고 더 쓰라는 말은 안 해요.

<br/>

<a id="guideline"></a>

## 📋 공공 가이드라인과의 관계

개인정보보호위원회 **「인공지능(AI) 개발·서비스를 위한 공개된 개인정보 처리 안내서」**(2024.7, 한국인터넷진흥원 지원)를 기준으로 점검했어요.

### 대부분은 해당되지 않아요 — 그게 핵심이에요

안내서가 밝힌 적용 대상은 **웹 스크래핑으로 모은 데이터셋에 개인정보가 들어 있고, 그걸로 AI를 학습시키는 경우**예요.

| 안내서의 전제 | KB Tune |
|---|---|
| 웹에서 데이터를 수집한다 | ✅ `tools/fetch_baseline.py` |
| **수집물에 개인정보가 있다** | ❌ 가져오는 건 **공표 통계 집계값**이에요 — 품목 평균가, 비목 월평균, 업종별 결제 **건당** 평균. 개인이 없어요 |
| **그 데이터로 모델을 학습시킨다** | ❌ 학습·파인튜닝을 하지 않아요. 이미 만들어진 모델에 물어보기만 해요 |
| 이용자가 입력한 문장을 학습에 쓴다 | ❌ 쓰지 않아요 |

그래서 안내서의 핵심인 **Ⅱ장(정당한 이익으로 학습데이터를 처리할 수 있는가)이 통째로 적용되지 않아요.**
암기·역류(regurgitation), 재식별, 학습된 모델에서 특정인 데이터를 지울 수 없는 문제 —
안내서가 다루는 위험들이 **구조적으로 생기지 않아요.** 학습을 안 하니까요.

### 필요한 조치들은 이미 코드에 있어요

서비스 단계에 적용되는 항목들이에요.

| 안내서 | 구현 |
|---|---|
| **Ⅲ-1-1** 로봇배제표준 준수 | [`fetch_baseline.py`](backend/tools/fetch_baseline.py) — 받아오기 전에 `robots.txt`를 확인하고, 막혀 있으면 중단해요 |
| **Ⅲ-1-2** 개인 식별자 삭제·비식별화<br/><sub>고유식별정보·민감정보·계좌·카드번호</sub> | [`OutboundPrivacy.sanitize()`](KB_Tune/AgentService.swift) + 서버 [`redact_personal_data()`](backend/app/security.py) — 안내서가 예시로 든 항목과 거의 같아요 |
| **Ⅲ-1-3** 안전한 저장·관리 | 기기 파일은 `completeFileProtection`, 백업 제외 |
| **Ⅲ-1-5** 프롬프트 필터 | [`safe_text()`](backend/app/security.py) — 제어문자를 지우고 사용자 입력을 '데이터'로 못박아요 |
| **Ⅳ** 삭제 요구권 | `ConsentStore.reset()` · `LocalStore.clear()` — 동의와 기기 저장 상태가 즉시 사라져요 |

> 자세한 내용은 [docs/security.md](docs/security.md) 에 있어요. 안내서는 법적 구속력이 없는 해석 기준이에요.

<br/>

<a id="stack"></a>

## 🛠 기술 스택

| 영역 | 사용 기술 |
|---|---|
| 📱 iOS | Swift · SwiftUI (iOS 26.5) · EventKit · Vision(기기 내 OCR) · PhotosUI |
| ⚙️ 백엔드 | Python · FastAPI · Uvicorn · httpx |
| 🤖 LLM | OpenAI API · OpenAI 호환 로컬 모델 · 오프라인 템플릿 |
| ✅ 테스트 | pytest · Swift Testing · XCUITest |

LLM은 `LLM_BACKEND`로 골라요. `offline`(템플릿, 비용 0) · `local`(OpenAI 호환, 비용 0) · `openai`.
무엇을 고르든 실패하면 템플릿으로 넘어가요.

<br/>

<a id="structure"></a>

## 📂 파일 구조

```
KB_Tune/                      iOS 앱 (SwiftUI, iOS 26.5)
├─ Models.swift               AppModel — 캘린더·예산·예측 상태의 단일 출처 + SpendState
├─ BudgetEngine.swift         추가 사용 가능액·목표 확률 (백엔드 엔진의 Swift 포트)
├─ WeekLedger.swift           주차별 장부 — 일수 배분 → 지난주 이월 → 이번 주 여유
├─ MatchEngine.swift          카드 결제 ↔ 캘린더 일정 연결 (계산 가능한 기준만 환산)
├─ SpendHistory.swift         과거 이력 → 반복 패턴 탐지 → 금액 예측 + 근거 문장
├─ SpendModel.swift           Gamma–Poisson·log-normal·Weibull 온디바이스 패턴 모델
├─ ForecastEngine.swift       LightGBM·q75·Hazard 중립 트리 온디바이스 추론
├─ ForecastModels.json        모델·피처 버전·집단 사전값·확률 보정 계수(원거래 없음)
├─ TuneScore.swift            목표·잔액·보호 소비를 결합한 Tune 점수와 신뢰도
├─ RiskDetector.swift         점수 하락·잔액 부족·일정/결제 중첩 선제 경보
├─ AdjustmentEngine.swift     보호 제약을 지킨 추천·보조·제외 조정안 비교
├─ TuneAudit.swift            판단 근거·사용자 승인·모델 버전 감사 로그
├─ TuneScoreView.swift        Tune 점수 상세·조정안·근거·감사 기록 화면
├─ EventEstimator.swift       일정 제목 → 예상 지출 (이력 → 공개 통계 → 규칙 순)
├─ BaselinePrices.swift       공개 통계 기준 금액 (번들 사본 + 서버에서 갱신)
├─ SearchQuery.swift          일정 제목 → 검색어 (코드에 있는 말로만 조립)
├─ baseline_prices.json       참가격·가계동향조사·상권분석에서 뽑은 기준 금액 표
├─ RecoEngine.swift           결정론 상품 추천 (연령·실적 하드필터 → 순혜택 계산)
├─ Products.swift             KB 상품 카탈로그 (기준서 v2 기반)
├─ ContentView.swift          진입 흐름 (스플래시 → 온보딩 → 메인 탭)
├─ MainTabView.swift          하단 4탭 · 스와이프 전환 · 주간 탭 재선택 시 초기화
├─ WeeklyPlanView.swift       주간·월간 계획, 타임테이블, Tune 점수, 예상 소비, 위험 조정
├─ ChatbotView.swift          대화 (백엔드 스트리밍 + 로컬 폴백)
├─ AnalysisView.swift         필수/기타 지출 분해 · 쓴 돈·나갈 돈 색 구분 · 캡처 업로드
├─ ProductsView.swift         현금흐름 요약 → 카드·적금 비교
├─ AddEventView.swift         일정 추가 3단계 (입력 → 추정·영향 → 확정)
├─ OnboardingView.swift       온보딩 (캘린더 연결 → 수입·목표 → 취향 → 방향)
├─ Consent.swift              동의 3항목 저장·철회 (제15조·제23조·제28조의8)
├─ ConsentView.swift          동의 화면 (원문을 접지 않고 항목마다 따로 받음)
├─ SettingsView.swift         수입·저축 목표·취향 수정
├─ CalendarStore.swift        EventKit 실연동 (기기 캘린더 읽기)
├─ AgentService.swift         질문 원문→금융 의도 변환 · 지난 소비/일정을 제목 없이 전달
├─ EventPhrase.swift          자연어 문장에서 날짜·금액 뽑기 (기기 안에서)
├─ LocalStore.swift           기기 저장 (보호등급 complete · 백업 제외)
├─ SpeechService.swift        온디바이스 음성 인식 (서버 전송 없음)
├─ OCRService.swift           기기 내 Vision OCR + 거래 구조화
├─ DemoClock.swift            데모 캘린더 기준일 (7/1을 1로 세는 통산일)
└─ DesignSystem.swift         KB 컬러 토큰 · 공용 스타일 · 금액 포맷

backend/                      FastAPI (선택 — 없어도 앱 동작)
├─ app/engine/                결정론 엔진 (계획·추정·분류·예측·확률)
├─ app/llm/                   OpenAI·로컬 모델 호출 (설명·대화)
├─ app/eval/                  골든 케이스 + groundedness 검사
├─ app/security.py            요청 인증·속도 제한·개인정보 마스킹·프롬프트 주입 방어
├─ app/baseline.py            공개 통계 기준 금액 (Firestore → 번들 폴백)
├─ app/llm/search.py          웹 검색으로 금액 찾기 (동의했을 때만)
├─ data/baseline_prices.json  기준 금액 표 (앱 번들과 같은 파일)
├─ tools/fetch_baseline.py    공개 데이터 3곳 → 기준 금액 표 재생성
├─ tools/seed_baseline.py     기준 금액 표 → Firestore
└─ app/data.py                데모 입력 (프로필·고정비·일정)

tools/forecast_bench/         모델 비교·피드백·개인화·위험·Hazard 재현 실험
├─ export_ondevice_models.py  선정 모델 JSON·Python↔Swift 골든 케이스 생성
└─ results/                   원시 예측·요약 CSV·bootstrap CI·KB 스타일 그래프
```

<br/>

<a id="run"></a>

## ▶️ 실행

**iOS**
```bash
open KB_Tune.xcodeproj      # Xcode 26.6+, iOS 26.5 시뮬레이터
```
`KB_Tune/`는 file-system-synchronized group이에요. `.swift` 파일을 넣으면 자동으로 빌드에 포함돼요.

**백엔드** (선택)
```bash
cd backend
pip install -r requirements.txt
cp .env.example .env         # 기본 LLM_BACKEND=offline — 키 없이 템플릿으로 동작
uvicorn app.main:app --reload
```

**테스트**
```bash
cd backend && PYTHONPATH=. .venv/bin/python -m pytest -q
xcodebuild test -project KB_Tune.xcodeproj -scheme KB_Tune \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

`KB_TuneTests/ForecastModelTests.swift`는 Python 골든 케이스와 Swift 트리 추론의
중앙값·q75·Hazard 확률·예상일이 같은지 별도로 막습니다.

기본 묶음은 키도 네트워크도 없이 돌아요. 문서용 캡처는 따로 잠가 뒀어요.

```bash
# docs/screens/ 에 화면 12장을 다시 찍어요 (기기 안에서만 모드 — 네트워크 불필요)
TEST_RUNNER_KB_TUNE_CAPTURE_ALL=1 \
TEST_RUNNER_KB_TUNE_SCREENSHOT_DIR=$PWD/docs/screens \
  xcodebuild test -scheme KB_Tune -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KB_TuneUITests/KB_TuneUITests/testCaptureAllScreens \
  -only-testing:KB_TuneUITests/KB_TuneUITests/testCaptureOnboarding
```

위에 보이는 App Store 스크린샷(`docs/appstore/`)은 이 캡처를 소재로 별도 편집기에서 만들어요.
제출용 원본은 6.9"(1320×2868) 8장이고, README에는 폭을 줄인 사본만 넣습니다.

실제 백엔드에 붙는 대화 캡처는 서버가 떠 있어야 해요.

```bash
cd backend && ./run.sh       # 먼저 백엔드를 띄우고
# XCUITest는 TEST_RUNNER_ 접두사가 붙은 것만 테스트 러너로 넘겨줘요.
TEST_RUNNER_KB_TUNE_LIVE_CHAT=1 \
TEST_RUNNER_KB_TUNE_SCREENSHOT_DIR=$PWD/../docs/screens \
  xcodebuild test -scheme KB_Tune -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KB_TuneUITests/KB_TuneUITests/testLiveChatAnswersPastSpendingScreenshot
```

<br/>

## 🗺 다음 과제

| 단계 | 기간 | 구현·검증 목표 | 완료 기준 |
|:--:|---|---|---|
| 1 | 완료 | Tune 점수·보호 제약·선제 경보·감사 로그 회귀 | 앱 재실행 복원·승인 없는 실행 0건·보호 소비 침해 0건 |
| 2 | 12주 | 20~50명 shadow-mode 시간 순 파일럿 | WAPE·편향·Brier·ECE·날짜 MAE·±1일 적중률 공개 |
| 3 | 통합 완료·실측 전 | 보정 LightGBM·q75·Hazard 온디바이스 추론 | Python↔Swift 골든 일치 완료·실기기 지연/배터리 측정 필요 |
| 4 | 파일럿 후 | 누적 Bayesian 승격 여부 재판정 | 미질문 WAPE 개선 95% CI 하한 > 0, 8주·12주 모두 통과 |
| 5 | 연동 단계 | KB Pay 샌드박스·토큰 인증·동의 철회 | 원본 미저장·철회 즉시 반영·위협모델 리뷰 |

<br/>

## 📚 참고 문헌

> 아래 문헌은 모델 구조와 평가 지표의 **방법론적 근거**입니다. KB Tune의 모델 선택과 성능 수치는
> 논문에서 가져온 값이 아니라 이 저장소의 동일 데이터 비교·신규 시드 홀드아웃 실험 결과입니다.
> 따라서 합성 데이터 결과를 실제 고객 성능으로 해석하지 않습니다.

1. <a id="ref-lightgbm"></a>Ke, G. et al. (2017).
   [*LightGBM: A Highly Efficient Gradient Boosting Decision Tree*](https://proceedings.neurips.cc/paper_files/paper/2017/hash/6449f44a102fde848669bdd9eb6b76fa-Abstract.html).
   Advances in Neural Information Processing Systems 30.
2. <a id="ref-quantile-regression"></a>Koenker, R. & Bassett, G. (1978).
   [*Regression Quantiles*](https://doi.org/10.2307/1913643).
   Econometrica, 46(1), 33–50.
3. <a id="ref-discrete-survival"></a>Gensheimer, M. F. & Narasimhan, B. (2019).
   [*A Scalable Discrete-Time Survival Model for Neural Networks*](https://doi.org/10.7717/peerj.6257).
   PeerJ, 7:e6257.
4. <a id="ref-weibull"></a>Weibull, W. (1951).
   [*A Statistical Distribution Function of Wide Applicability*](https://doi.org/10.1115/1.4010337).
   Journal of Applied Mechanics, 18(3), 293–297.
5. <a id="ref-brier"></a>Brier, G. W. (1950).
   [*Verification of Forecasts Expressed in Terms of Probability*](https://doi.org/10.1175/1520-0493(1950)078%3C0001:VOFEIT%3E2.0.CO;2).
   Monthly Weather Review, 78(1), 1–3.
6. <a id="ref-pr-curve"></a>Davis, J. & Goadrich, M. (2006).
   [*The Relationship Between Precision-Recall and ROC Curves*](https://doi.org/10.1145/1143844.1143874).
   Proceedings of the 23rd International Conference on Machine Learning, 233–240.
7. <a id="ref-cqr"></a>Romano, Y., Patterson, E. & Candès, E. J. (2019).
   [*Conformalized Quantile Regression*](https://proceedings.neurips.cc/paper_files/paper/2019/hash/5103c3584b063c431bd1268e9b5e76fb-Abstract.html).
   Advances in Neural Information Processing Systems 32.
8. <a id="ref-adaptive-conformal"></a>Gibbs, I. & Candès, E. J. (2021).
   [*Adaptive Conformal Inference Under Distribution Shift*](https://proceedings.neurips.cc/paper/2021/hash/0d441de75945e5acbc865406fc9a2559-Abstract.html).
   Advances in Neural Information Processing Systems 34.
9. <a id="ref-chronos2"></a>Ansari, A. F. et al. (2025).
   [*Chronos-2: From Univariate to Universal Forecasting*](https://arxiv.org/abs/2510.15821).
   arXiv:2510.15821.

<br/>

<div align="center">
<sub>KB AI Challenge 2026 · 내부 검토용</sub>
</div>
