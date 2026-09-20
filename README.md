# LabLink

국내 대학 연구실 탐색과 연구 협업 제안을 위한 웹 애플리케이션입니다. 연구실과 논문 정보는 공식 출처, 확인일, 검수 상태를 함께 보존하도록 설계했습니다.

## 포함된 기능

- 연구실 검색·대학 필터·상세 페이지·관심 연구실 저장
- 연구실별 공식 출처 기반 소개, 교수 이력, 공개된 졸업생 진로, 장비·기술, 논문
- 이메일 로그인, 연구자 공개 프로필, 협업 공고, 협업 제안과 상태 변경
- Supabase RLS 정책과 서버 측 RPC로 보호하는 사용자 데이터
- 승인한 연구실 홈페이지만 대상으로 하는 변경 감지 수집 파이프라인

## 로컬 실행

Node.js 22와 pnpm 11이 필요합니다.

```bash
pnpm install --frozen-lockfile
copy .env.example .env.local
pnpm dev
```

`.env.local`에는 브라우저에서 사용 가능한 Supabase 프로젝트 URL과 publishable(또는 legacy anon) 키만 넣습니다.

```dotenv
VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_PUBLIC_KEY
```

`SUPABASE_SECRET_KEY`는 절대로 `VITE_` 접두사로 만들거나 브라우저에 노출하지 않습니다.

## Supabase 적용

1. 새 Supabase 프로젝트를 만들고 Authentication에서 이메일 로그인을 켭니다.
2. SQL Editor에서 다음 파일을 순서대로 실행합니다.

   - `supabase/migrations/202609170001_initial.sql`
   - `supabase/migrations/202609180002_hardening.sql`
   - `supabase/migrations/202609200003_existing_db_extensions.sql`
   - `supabase/migrations/202609200004_paper_review_pipeline.sql`
   - `supabase/migrations/202609210005_paper_discovery_review.sql`
   - `supabase/seeds/pilot-labs.sql` (시범 데이터가 필요할 때만)

3. 앱의 `.env.local`에 URL과 publishable/anon 키를 넣습니다.
4. 두 개의 테스트 계정을 만들어, `supabase/tests/access.sql`의 점검 항목을 실행합니다.
5. `supabase/tests/paper_review.sql`을 실행해 승인 트랜잭션을 점검합니다. 테스트 데이터는 마지막에 전부 롤백됩니다.

시드 데이터는 2026-09-17~18에 검토한 파일럿 목록이며 전체 연구실 또는 완전한 논문 목록이 아닙니다. 실제 공개 전에는 각 출처 URL과 내용, 확인일을 다시 검수해야 합니다.

## 데이터 수집

수집기는 공개 URL을 받는 기능이 아닙니다. `private.sources`에 운영자가 검토해 등록하고 활성화한 출처만 대상으로 합니다.

```bash
# 수집기 안전성 및 추출 테스트
pnpm test

# 파일럿 출처를 실제 DB에 쓰지 않고 확인
CRAWLER_CONTACT=mailto:operator@example.org pnpm crawl:dry
```

운영 수집은 GitHub Actions의 `Collect reviewed lab sources` 워크플로를 사용합니다. GitHub 저장소에 다음을 설정한 뒤 `CRAWLER_ENABLED=true` 변수로 명시적으로 켭니다.

- Secrets: `SUPABASE_URL`, `SUPABASE_SECRET_KEY`
- Variables: `CRAWLER_CONTACT`, `CRAWLER_ENABLED`

수집 결과는 즉시 공개하지 않습니다. 변경 내용은 `private.candidates`에 후보로 저장되며, 운영자가 근거와 내용을 검수해 공개 테이블에 반영해야 합니다.

### 논문 검토와 등록

출판 페이지에서 발견한 DOI는 `private.paper_candidates`에 하나씩 분리됩니다. 이 큐와 검토 RPC는 `service_role`만 사용할 수 있으며 브라우저 키로는 접근할 수 없습니다. 운영 환경에서 다음처럼 검토합니다.

```bash
# 대기 중인 DOI 후보 확인
SUPABASE_URL=... SUPABASE_SECRET_KEY=... pnpm papers:list

# pipeline/paper-review.example.json을 복사해 출처를 직접 확인한 값으로 작성한 뒤 승인
node pipeline/review.mjs approve CANDIDATE_UUID --file reviewed-paper.json

# 잘못 연결된 DOI 등은 근거를 남기고 반려
node pipeline/review.mjs reject CANDIDATE_UUID --reviewer OPERATOR --note "반려 사유"
```

승인은 논문과 연구실 연결을 한 트랜잭션에서 만들고 `published`로 전환합니다. 요약은 근거가 `abstract` 또는 `full_text`로 지정된 경우에만 저장되며, 교신저자 `confirmed` 표시는 HTTPS 증거 URL이 있을 때만 허용됩니다. 모든 승인·반려는 `private.audit_logs`에 기록됩니다.

### 최근 5개년 논문 조사

`pipeline/lab-paper-sources.json`에는 5개 파일럿 연구실 책임교수의 OpenAlex Author ID, ORCID, 현재 소속과 검토 근거 URL을 저장합니다. 다음 명령은 2022~2026년 DOI 논문을 수집해 `work/paper-discovery.json`을 만듭니다.

```bash
pnpm papers:discover
```

GitHub Actions의 `Discover five-year lab papers` 워크플로는 같은 조사를 수행하고 서비스 키로 후보를 Supabase에 적재합니다. 후보는 공개 논문으로 전환되지 않으며 `/paper-review`에서 제목·저자·DOI·소속 근거를 확인할 수 있습니다. 로그인한 사용자는 `논문 확인`, `보류`, `대상 제외` 의견을 남길 수 있고, 실제 공개는 기존 운영자 승인 RPC를 거쳐야 합니다.

## Cloudflare Pages 배포

GitHub 저장소를 Cloudflare Pages에 연결하고 다음 값을 사용합니다.

| 설정 | 값 |
| --- | --- |
| Framework preset | Vite |
| Build command | `pnpm build` |
| Build output directory | `dist` |
| Node.js version | `22` |

Preview와 Production 환경 각각에 `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`를 설정합니다. 두 환경은 서로 다른 Supabase 프로젝트를 사용하는 편이 안전합니다. `public/_redirects`는 상세 주소를 새로고침해도 앱으로 돌아오게 합니다.

## 검증 명령

```bash
pnpm test
pnpm build
```

배포 전에는 홈·검색·상세 주소 직접 열기/새로고침·로그인·두 계정 간 제안/응답·모바일 공고 등록을 확인합니다. API 오류는 전체 화면을 중단시키지 않고 재시도 안내를 보여야 합니다.

## 운영 원칙

- 공개 연구실 정보에는 출처와 확인일을 남깁니다.
- 마지막 저자라는 이유만으로 교신저자로 표기하지 않습니다.
- 공개 홈페이지의 교수·졸업생 정보와 LabLink 가입 계정은 별개입니다.
- 논문 본문을 무단 저장·재배포하지 않습니다. 요약의 근거와 검수 상태를 보존합니다.
- 장비 경험, 장비 보유, 외부 이용 가능 여부는 분리해 다룹니다.
