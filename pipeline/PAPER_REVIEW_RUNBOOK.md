# 논문 검토 실행 지침 — 저토큰 순차 실행

> 2026-09-25: 새 제품 방향과 후속 계획/구현은 PAPER_PUBLICATION_GUIDELINES.md가 우선한다. 이 문서는 이전 실행 절차·이력 참고용이다. 새 지침은 운영자 조사 후 공개, 근거 있는 공식 저장소 대체 경로, 요약·키워드·연도별 IF 보강을 정의한다.

상태: 방법만 수립. 이 문서 작성 과정에서 논문 검토·승인·제외·DB 저장을 실행하지 않았다.
모델 이름에 종속되지 않는 지침이다. 사용자가 sol-light로 전환한 다음 실행을 요청할 때 적용한다.

## 범위와 실행 시작

- 대상: 실행 시작 시 DB에서 pending인 5개 연구실 후보. 기준 기간은 2022–2026년이며 2026년은 조사 시점까지다. 과거 383건은 참고 수치이며 실제 현재 건수를 다시 읽는다.
- 연구실: hanyang-escml / Yang-Kook Sun, snu-mest / Jang Wook Choi, snu-aeml / Kisuk Kang, unist-cho / Jaephil Cho, hanyang-aetl / Hansu Kim.
- OpenAlex 검색 결과는 후보 목록일 뿐 검증 근거가 아니다. 383건이 전체 논문을 빠짐없이 포함한다는 의미도 아니다.
- 실행 요청 전에는 수집·검토·DB 변경을 하지 않는다. 실행 요청 후 승인 조건을 충족한 후보는 아래 RPC로 저장한다. 사람의 확인 투표를 대신 만들지 않는다.
- 처음에는 이 문서와 체크포인트만 읽는다. 필요할 때만 pipeline/review.mjs, review-core.mjs, 관련 SQL을 읽는다. 전체 대화 기록·후보 383건·HTML 전체를 매번 읽지 않는다.

## 1. 사전 점검 (읽기부터)

1. public.labs에서 slug, name, professor, homepage를 조회한다. 홈페이지를 임의로 추측하지 않는다. pipeline/lab-paper-sources.json의 ORCID는 교수 식별 보조이며 연구실 출판 목록을 대체하지 않는다.
2. public.list_paper_review_queue(null,null,1000)로 검토 목록을 가져와 로컬 파일에 저장한다. 이 목록에 candidate_id가 있다. 실제 쓰기 전에는 해당 후보의 상태를 다시 확인한다.
3. 서버 환경에 SUPABASE_URL, SUPABASE_SECRET_KEY가 있는지 값 출력 없이 확인한다. 공개 키로 승인 RPC를 실행할 수 없다. 서비스 키를 채팅·문서·브라우저 번들·Git에 넣지 않는다. 키가 없으면 근거 검토와 로컬 결과까지 진행하고 DB 저장만 보류한다.
4. 현재 승인 RPC는 public.approve_paper_candidate(uuid,jsonb), 제외 RPC는 public.reject_paper_candidate(uuid,text,text)다. 운영 DB의 함수 정의와 로컬 migration을 대조한다. 이전에 UI 입력 과정에서 정규식의 역슬래시가 손실된 전력이 있어 DOI 검증을 읽기 전용으로 점검한다. PostgreSQL 자체가 \\S를 지원하지 않는다는 이전 주석은 정확하지 않다. 실제 저장된 식을 확인해야 한다. 승인 함수가 틀렸다면 별도 수정·검증 후 쓰기를 진행한다.
5. pipeline/review.mjs list에는 인자 파싱상 --limit 위치 문제가 있고 최대 200건 제한이 있다. 전체 큐는 위 list_paper_review_queue RPC로 읽는다. DB 접근 방법이 없으면 실행 가능한 것처럼 주장하지 않는다.

## 2. 연구실 홈페이지 출판 목록 확인 (반드시 먼저)

1. 공식 홈페이지에서 Publications, Papers, Research output, 논문, 출판 등 실제 링크를 따라간다. 대학 교수 디렉터리에서 공식 도메인 및 교수 신원을 교차 확인한다.
2. 각 연구실의 2022–2026년 페이지, 다음 페이지, 접힌 연도 목록을 확인하고 DOI/제목/연도/출처 URL을 작은 인덱스로 저장한다. 접근 실패·robots 제한·페이지 일부 누락은 기록한다.
3. 후보 DOI를 정규화해 목록과 매칭한다. DOI가 없으면 제목, 저자, 연도 조합으로 후보를 좁힌다. 제목 정규화는 대소문자·공백·일반 문장부호만 처리하며 수식·그리스문자 차이를 무시하지 않는다.
4. 목록에 없다는 사실만으로 제외하지 않는다. 홈페이지가 미갱신 또는 불완전하면 hold로 기록한다. 홈페이지에서 추가 발견한 논문은 missing-candidates에 별도 기록하고 기존 pending 범위를 자동 확대하지 않는다.

## 3. 논문별 인터넷 교차 확인

1. DOI 원문 링크를 열어 출판사 논문 페이지의 DOI, 제목, 저자, 저널, 출판일과 소속을 확인한다. 인터넷 검색이 필요하면 DOI 정확 검색 → 제목과 교수명 검색 순으로 진행한다.
2. 출판사 또는 Crossref/공식 저장소의 실제 레코드를 읽는다. 검색 스니펫만으로 승인하지 않는다. OpenAlex와 ORCID가 같은 데이터를 재사용한 경우 독립 근거 두 개로 세지 않는다.
3. 승인에는 공식 연구실 출판 목록의 해당 항목과 독립된 논문 레코드가 모두 필요하다. DOI 일치 + 제목 일치 + 해당 교수의 저자 포함 + 해당 논문의 연구실 소속 근거 + 기간 일치를 확인한다.
4. 현재 교수 소속으로 과거 논문 소속을 추론하지 않는다. 논문 당시 기관을 확인한다. 이전 기관 논문은 previous_affiliation로 기록하고 현재 연구실 실적으로 자동 승인하지 말고 hold한다.
5. 교신저자는 출판사 corresponding author 표기 또는 합법적으로 공개된 논문 첫 페이지의 명시적 근거로만 confirmed. 마지막 저자라는 이유로 판단하지 않는다. 확인 못 하면 unknown이며 논문 자체의 다른 요건이 충족되면 승인 가능하다.
6. online-first 연도와 권호 연도가 다르면 두 날짜를 근거에 기록한다. 정책상 출판사 정식 서지 연도를 사용하며 기간 경계 충돌은 hold. 미래 예정일을 이미 출판된 논문으로 취급하지 않는다.
7. preprint, editorial, correction, proceedings는 research article과 구분한다. 현재 public.papers의 문헌 유형 표시 제약을 고려해 기본 자동 승인은 정식 article/review만 허용한다. 나머지는 hold로 유형을 남긴다. preprint와 정식 출판 DOI가 다르면 동일 논문의 관계를 기록하고 두 건을 중복 실적으로 승인하지 않는다.
8. 철회 표시를 확인하면 hold하고 사유를 남긴다. 유료 원문·접근 제한을 우회하지 않는다. 초록과 서지만으로 조건 확인이 가능하면 본문을 다운로드할 필요 없다.

## 4. 판정

| 결정 | 조건 | DB 처리 |
| --- | --- | --- |
| approve | 공식 목록 및 독립 출처가 일치하고 기간·저자·논문 당시 소속 확인 | 승인 RPC 실행 |
| hold | 정보 부족, 접근 불가, 충돌, 유형·소속·날짜 불명확 | pending 유지, 로컬 근거와 사유 저장 |
| reject | 동명이인, 다른 논문 DOI, 명확한 기간 밖 등 오류를 입증 | 제외 RPC, 구체적 근거 기록 |

자동 요약은 이 검토 작업에서 생성하지 않는다. summary와 summary_basis는 null. 제목만 읽고 연구 내용을 추론하지 않는다.

## 5. 파일 형식과 체크포인트

작업 폴더 work/paper-review/ 아래 다음을 저장한다. 파일은 편집 도구로 생성하며 버전 관리에 키나 토큰을 포함하지 않는다.

- scope.json: run_id, started_at, 기간, 최초 pending ID 목록, 연구실 순서.
- sources/<lab>.json: 공식 홈페이지, publication URL 목록, 확인일, 연도별 커버리지, 접근 실패 사유.
- evidence/<candidate_id>.json: candidate_id, lab_slug, doi, decision, checked_at, lab_evidence {url, 짧은 해당 항목}, external_evidence {url, DOI/제목/저자/연도/소속}, 대응저자 근거, 충돌, 사유. 장문 원문 복사 금지.
- reviews/<candidate_id>.json: 아래 승인 RPC 형식. evidence 파일과 동일 DOI/연구실인지 검사.
- checkpoint.json: 마지막 처리 ID, 완료 ID, 다음 ID, 승인/제외/보류 건수, DB 저장 확인 상태, 미해결 오류. 매 후보 완료 후 갱신한다.
- missing-candidates.json: 공식 목록에서 발견했지만 큐에 없는 논문. 자동 승인하지 않는다.

리뷰 JSON 필드:
title, year(정수), journal, doi, source_url(HTTPS 출판사/DOI), faculty_name,
corresponding_status(confirmed/unknown/not_corresponding), evidence_url,
affiliation_scope(current_lab/previous_affiliation/unverified), summary:null,
summary_basis:null, reviewer:"agent-assisted:<run_id>", review_note.

review_note에는 공식 출판 목록 URL, 독립 출처 URL, 확인일, 판정 근거, evidence 파일 식별자를 짧게 넣어 DB에도 검증 출처가 남도록 한다. evidence_url은 confirmed이면 교신저자 직접 근거 URL, 그 외 공식 목록 URL을 사용한다. 저자 전체 목록·문헌 유형은 현재 승인 RPC가 public.papers에 저장하지 않으므로 evidence에 보존하고 저장됐다고 주장하지 않는다.

## 6. 저장 및 확인

서버 환경에 키가 안전하게 제공된 뒤 저장한다. 값은 명령줄에 직접 넣지 않는다.

```text
node pipeline/review.mjs approve <candidate-uuid> --file work/paper-review/reviews/<candidate-uuid>.json
node pipeline/review.mjs reject <candidate-uuid> --reviewer agent-assisted:<run_id> --note <검증된-사유>
```

- 먼저 1건만 승인해 반환 paper_id, private.paper_candidates.status=approved, public.papers의 DOI/연도, public.lab_papers의 lab_id/paper_id와 evidence_url, audit log를 확인한다. 승인은 즉시 연구실 공개 논문에 반영된다.
- 같은 DOI를 여러 연구실이 공저했으면 public.papers 한 건에 lab_papers 연결 여러 개가 가능하다. 전역 중복이라고 다른 연구실의 합당한 연결을 제외하지 않는다.
- RPC 타임아웃은 실패로 단정하지 않는다. 후보 상태와 paper_id를 다시 읽어 저장 여부를 확인한 다음 재시도를 결정한다. 이미 approved/rejected면 자동 재실행하지 않는다.
- 승인 RPC는 기존 같은 DOI의 공유 논문 메타데이터를 갱신한다. 기존 값과 충돌하면 자동 덮어쓰기를 중단하고 hold한다.
- 정상 1건 검증 후에도 1건씩 순차 저장, 10건마다 DB 상태와 체크포인트 대조. hold는 사용자 투표 RPC로 대리 투표하지 않는다.

## 7. sol-light 저토큰 운영

- 연구실 하나, 연도 하나, 최대 10건을 한 배치로 처리한다. 전체 레코드는 파일에 저장하고 모델에는 현재 배치의 필요한 필드만 전달한다.
- 공식 출판 목록은 연구실·연도별 한 번 확인해 캐시한다. 논문별로 반복 탐색하지 않는다. 독립 논문 근거는 각 DOI별 최소 한 번 확인해야 한다.
- 후보당 검색은 기본 2회, 직접 근거 페이지 확인은 기본 3개 이내. 해결되지 않으면 hold 후 다음 후보로 간다. 시간 지연과 재시도는 모델 설명 대신 도구에서 처리하며 429/5xx에는 최대 3회 지수 백오프를 쓴다.
- 10건마다 짧은 진행 보고와 체크포인트를 기록한다. 응답에는 건수·중요 예외만, 장문 페이지/전체 JSON/반복 계획은 출력하지 않는다.
- 중단·모델 전환 후 scope + checkpoint + 현재 배치만 읽고 재개한다. 최초 실행 때 받은 실행 권한과 범위를 유지하되 새 후보·연도 확장은 별도 요청으로 다룬다.
- 종료 보고: 최초 대상 수 = 승인 + 제외 + 보류 + 미처리. DOI 고유 수와 연구실-논문 연결 수를 구분한다. 출판 목록 누락·접근 실패 때문에 전수 검증을 못 했으면 명시한다.

## 인증 설정 운영 기록 (2026-09-22)

Supabase Site URL의 localhost:3000을 https://lab-link.pages.dev로 변경했고 Redirect URLs에 https://lab-link.pages.dev/me를 등록했다. 코드의 signUp.emailRedirectTo는 location.origin + '/me'다. 기존 메일 링크는 새 설정으로 소급 변경되지 않는다. 이미 인증된 사용자는 /me에서 기존 비밀번호로 로그인한다. 실제 사용자 메일 인증 완료는 사용자가 확인해야 한다.
