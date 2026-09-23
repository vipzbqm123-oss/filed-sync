# FieldSync 운영 문서 (RUNBOOK.md)

> 대상: 서버를 배포·운영하는 담당자 · 기준일 2026-09-23 · 구조 설명은 `DEVELOPMENT.md`, 설계 근거는 `GUIDE.md`
> 표기: `<ref>` = Supabase 프로젝트 ref, `$CRON_SECRET` 등 = 직접 만든 비밀값. 비밀값은 문서·채팅·로그에 붙여 넣지 않습니다.

## 1. 준비물

| 항목 | 용도 | 비고 |
|---|---|---|
| Supabase 프로젝트 | DB·Auth·Realtime·Storage·Edge Functions | 리전은 사용자와 가까운 곳(서울) 권장 |
| Supabase CLI | 마이그레이션·함수 배포·비밀 설정 | `supabase --version`으로 확인 |
| 카카오 개발자 앱 | 네이티브 앱 키(지도, 앱에 넣음), REST API 키(주소 검색, 서버에만) | 플랫폼에 Android 패키지명·키 해시, iOS 번들 ID 등록 |
| Firebase 프로젝트 | FCM 푸시 | Android·iOS 앱 등록, 서비스 계정 JSON, APNs 인증 키(.p8) |
| Flutter 3.38.1+ | 앱 빌드 | Xcode(iOS), Android SDK 36 |
| 비밀값 1개 생성 | `CRON_SECRET` (pg_cron → push 호출 인증) | 예: `openssl rand -hex 32` |

## 2. 최초 배포 (순서대로)

### 2.1 Auth 설정 — 자가 가입 차단 (필수, 보안)

1. Dashboard → Authentication에서 **이메일/비밀번호 로그인은 켜고, "새 사용자 가입 허용(Allow new users to sign up)"은 끕니다.** 계정은 관리자만 발급합니다(`admin-users` 함수는 관리 API를 쓰므로 가입을 꺼도 동작).
2. 앱 로그인 ID는 내부적으로 `<ID>@staff.fieldsync.local` 형태의 가상 이메일로 쓰입니다. 실제 메일은 발송되지 않습니다.
3. 2중 방어로, 가입 API로 생긴 계정(`app_metadata`에 role 없음)은 DB가 **비활성**으로 만듭니다(`50_rls.sql` R8에서 검증).

### 2.2 확장 기능 켜기

Dashboard → Database → Extensions에서 `pg_cron`, `pg_net`을 켭니다. 켜 두지 않아도 마이그레이션이 자동으로 켜기를 시도하지만, 권한 정책에 따라 실패할 수 있으니 먼저 켜 두는 것이 안전합니다.

### 2.3 DB 마이그레이션

```bash
supabase login
supabase init                       # 처음 한 번(supabase/config.toml 생성, 기존 migrations는 유지)
supabase link --project-ref <ref>
supabase db push                    # supabase/migrations 4개 파일을 순서대로 적용
```

CLI 대신 SQL Editor를 쓸 수도 있습니다. `supabase/migrations/`의 파일을 이름 순서(001 → 004)대로 붙여 넣어 실행합니다. `supabase/tests/00_supabase_stub.sql`은 **로컬 테스트 전용이므로 운영에 실행하면 안 됩니다.**

적용 확인(SQL Editor):

```sql
select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('claim_site','complete_work','claim_push_batch');   -- 3
select jobname, schedule from cron.job where jobname like 'fieldsync-%';                         -- 2행
select id, public, file_size_limit from storage.buckets where id = 'evidence';                     -- false, 5242880
```

### 2.4 Vault 비밀(DB → push 함수 호출용)

```sql
select vault.create_secret('https://<ref>.supabase.co', 'project_url');
select vault.create_secret('<CRON_SECRET 값>', 'cron_secret');
select name from vault.decrypted_secrets where name in ('project_url', 'cron_secret');   -- 2행(값은 조회하지 않음)
```

둘 중 하나라도 없으면 `private.kick_push()`가 아무것도 하지 않습니다. 이 경우 원격 푸시가 나가지 않지만, 앱 로컬 리마인더는 정상 동작합니다.

### 2.5 Edge Functions

```bash
supabase secrets set KAKAO_REST_KEY=<카카오 REST 키> CRON_SECRET=<CRON_SECRET 값>
supabase secrets set FCM_SERVICE_ACCOUNT="$(cat <서비스계정>.json)"
supabase functions deploy geocode --no-verify-jwt       # 함수가 직접 Auth(/auth/v1/user)로 토큰 검증
supabase functions deploy admin-users --no-verify-jwt   # 〃 + 관리자 여부 확인
supabase functions deploy push --no-verify-jwt          # pg_cron이 x-cron-secret 헤더로 호출(JWT 없음)
```

세 함수 모두 요청마다 스스로 인증합니다(토큰 없거나 무효면 401). 그래서 게이트웨이 JWT 검증을 끄고 배포해도 안전하고, JWT 서명 키 방식(대칭·비대칭)이 바뀌어도 영향을 받지 않습니다. `SUPABASE_URL`과 키는 Supabase가 자동으로 넣어 줍니다(새 키 우선, 없으면 레거시 키). 서비스 계정 JSON은 Firebase 콘솔 → 프로젝트 설정 → 서비스 계정 → 새 비공개 키 생성에서 받습니다.

동작 확인:

```bash
curl -s -X POST https://<ref>.supabase.co/functions/v1/push -H "x-cron-secret: $CRON_SECRET"
# → {"sent":0,"failed":0,"removed_tokens":0} (보낼 알림이 없을 때)
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://<ref>.supabase.co/functions/v1/push -H "x-cron-secret: wrong"
# → 401
```

### 2.6 첫 관리자 만들기

1. Dashboard → Authentication → Users → Add user를 누릅니다. 이메일 `admin@staff.fieldsync.local`(앱 로그인 ID = `admin`)과 비밀번호를 넣고, 자동 확인(Auto Confirm)을 켭니다.
2. 새 계정은 작업자로, 가입 방어 규칙에 따라 비활성으로 생성될 수 있습니다. SQL Editor에서 관리자로 승격하고 활성화합니다.

   ```sql
   update public.profiles set role = 'admin', active = true where login_id = 'admin';
   ```
3. 이후 계정은 앱의 관리 → [사용자·등급] → [계정 발급]으로 만듭니다.

### 2.7 앱 빌드

```bash
cd app
flutter create --platforms android,ios --org <회사도메인> .
rm test/widget_test.dart
# app/platform/ 조각 병합 → android/app/src/main/AndroidManifest.xml · android/app/build.gradle.kts · android/app/proguard-rules.pro · ios/Runner/Info.plist · ios/Runner/AppDelegate.swift · ios/Podfile(iOS 14.0)
flutterfire configure                  # google-services.json / GoogleService-Info.plist 추가
cp env.example.json env.json           # SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, KAKAO_NATIVE_APP_KEY 입력(커밋 금지)
flutter pub get && flutter analyze && flutter test
flutter build appbundle --dart-define-from-file=env.json     # Android
flutter build ipa --dart-define-from-file=env.json           # iOS
```

- **카카오 키 해시(Android)**: 디버그·릴리스 서명별로 다릅니다. `KakaoMapSdk.instance.hashKey()`로 확인해 카카오 콘솔 플랫폼에 등록합니다. 미등록이면 지도가 표시되지 않습니다.
- **APNs(iOS)**: Apple Developer → Keys에서 APNs 키(.p8)를 만들고, Firebase → Cloud Messaging의 Apple 앱 설정에 올립니다. Xcode에서 Push Notifications와 Background Modes(Remote notifications)를 켭니다.
- **앱에 들어가는 키**: publishable 키(공개용, RLS로 보호)와 카카오 네이티브 키만 들어갑니다. secret 키, 카카오 REST 키, 서비스 계정은 절대 넣지 않습니다.

### 2.8 배포 후 점검표

| # | 점검 | 방법 | 기대 |
|---|---|---|---|
| 1 | 자가 가입 차단 | `curl -s -X POST https://<ref>.supabase.co/auth/v1/signup -H "apikey: <publishable 키>" -H 'Content-Type: application/json' -d '{"email":"probe@staff.fieldsync.local","password":"probe-12345"}'` | 가입 거부 오류. 만약 가입되면 2.1을 다시 확인(계정은 비활성으로 생성됨) |
| 2 | 로그인 | 앱에서 관리자 로그인 | 홈 화면 |
| 3 | 동선 배포 | 관리 → 동선 생성 → 주소 검색 추가 → 배포 | 작업자 앱에 표시, 배정 팀에 알림 |
| 4 | 중복 방지 | 작업자 2명이 같은 현장 [맡기] | 한 명만 성공, 다른 쪽에 점유자 이름 표시 |
| 5 | 리마인더 | 정책을 임시로 짧게(예: 첫 알림 5분) → 작업 시작 후 대기 | 로컬 알림 수신, `work_logs`에 remind 기록 |
| 6 | 원격 푸시 | 팀장이 긴급 요청 | 다른 사용자 폰에 푸시, 해당 알림 행이 `sent_at` 있음 + `last_error` 없음(`NO_DEVICE`면 그 사용자 기기 토큰 없음) |
| 7 | 정책 원복 | 관리 → [알림·점유 정책] | 기본값(USER_GUIDE §8) |

## 3. 일상 운영

### 3.1 상태 조회 쿼리 (SQL Editor, 읽기 전용)

```sql
-- 푸시 적체·실패(최근 1일)
select count(*) filter (where sent_at is null)                       as pending,
       count(*) filter (where sent_at is null and attempts >= 5)     as gave_up,
       count(*) filter (where last_error = 'NO_DEVICE')              as no_device
  from public.notifications where created_at > now() - interval '1 day';

-- 오래 작업중인 세션(4시간 초과)
select s.bunji, p.name, ws.status, ws.started_at, ws.remind_count
  from public.work_sessions ws join public.sites s on s.id = ws.site_id join public.profiles p on p.id = ws.user_id
 where ws.status in ('working', 'paused') and ws.started_at < now() - interval '4 hours'
 order by ws.started_at;

-- 크론 실행 결과(최근 10회)
select jobid, status, return_message, start_time from cron.job_run_details order by start_time desc limit 10;

-- push 함수 호출 응답(pg_net)
select status_code, left(content::text, 200) as body, created from net._http_response order by created desc limit 10;

-- 오늘(서울 기준) 차단된 중복 시도 수 — 통계 화면(get_stats)과 같은 기준
select count(*) from public.work_logs
 where not ok and meta -> 'result' ->> 'code' = 'SITE_OCCUPIED'
   and (at at time zone 'Asia/Seoul')::date = (now() at time zone 'Asia/Seoul')::date;
```

### 3.2 정기 작업

| 주기 | 작업 |
|---|---|
| 매일 | 3.1의 푸시 적체·장기 작업중 확인 |
| 매주 | 3.1의 `net._http_response`에서 push 응답이 200이 아닌 건(본문에 `FCM_AUTH` 등) 확인, 관리자에게 주소 등록 실패(`카카오 호출 한도 초과`) 여부 확인 |
| 앱 배포 시 | 새 버전 배포 → 스토어 반영 확인 → 관리 → 정책의 **최소 앱 버전**을 올려 구버전 사용자에게 업데이트 배너 표시 |
| 분기 | 퇴사자 계정 사용 중지, 비밀값(CRON_SECRET 등) 교체 검토 |

## 4. 장애 대응

| 증상 | 확인 | 조치 |
|---|---|---|
| 원격 푸시가 안 옴 | ① 3.1 pending·no_device ② `cron.job_run_details` ③ `net._http_response`의 status·본문 ④ Edge 로그(예상 못 한 내부 오류만 기록됨) | 401이면 Vault `cron_secret`과 Edge `CRON_SECRET` 불일치 → 둘을 같게. `FCM_AUTH`면 서비스 계정 재발급. `NO_DEVICE`면 해당 사용자가 앱에서 알림 권한 허용·재로그인 |
| 로컬 리마인더가 안 울림 | 앱 [설정] → [알림 테스트] | 폰 설정에서 앱 알림 허용, Android 배터리 최적화 제외 |
| 작업자가 현장을 잡은 채 연락 두절 | 현장 상세 | 관리자 또는 그 작업자 팀의 팀장(권한 `강제 해제(팀)`)이 [강제 해제]하고 사유 입력 → 대상자에게 알림 |
| 퇴사자 처리 | 관리 → [사용자·등급] → [사용 중지] | `점유 중인 현장이 있어 처리할 수 없습니다`가 뜨면 먼저 강제 해제 |
| `비활성 처리됨(로그인 차단은 잠시 후 재시도)` 표시 | DB 차단은 이미 적용됨(데이터·RPC 접근 불가, 로그인해도 앱이 즉시 로그아웃) | 로그인 자체도 막으려면 잠시 후 [사용 재개] → [사용 중지]를 다시 실행 |
| 관리자 전원 잠김 | — | ① SQL: `update public.profiles set role='admin', active=true where login_id='<ID>';` ② 앱에서 중지했던 계정이면 로그인 차단도 해제: `update auth.users set banned_until = null where email = '<ID>@staff.fieldsync.local';` ③ 비밀번호를 모르면 Dashboard → Authentication → Users에서 재설정 |
| CSV 결과의 실패 행 사유가 `카카오 호출 한도 초과` | 카카오 콘솔 사용량 | 한도 회복 후 실패 행만 다시 올림(이미 등록된 행은 중복으로 자동 제외) |
| 주소 검색·등록 시 `카카오 REST 키 확인 필요` | Edge 비밀 `KAKAO_REST_KEY` | 키 재설정 후 `supabase functions deploy geocode --no-verify-jwt` |
| DB 일시 장애·점검 | Supabase 상태 페이지 | 앱은 요청을 대기열에 보관하고, 복구되면 순서대로 자동 전송합니다(5→60초 간격 재시도). 별도 조치 없음 |
| 지도가 회색/빈 화면 | 카카오 콘솔 플랫폼 | 키 해시·번들 ID 등록, 네이티브 앱 키 확인 |

## 5. 비밀값 교체

| 대상 | 절차 |
|---|---|
| `CRON_SECRET` | ① `supabase secrets set CRON_SECRET=<새 값>` ② `select vault.update_secret((select id from vault.secrets where name = 'cron_secret'), '<새 값>');` ③ `supabase functions deploy push --no-verify-jwt` ④ 2.5의 curl로 확인 |
| 카카오 REST 키 | `supabase secrets set KAKAO_REST_KEY=…` → `supabase functions deploy geocode --no-verify-jwt` |
| FCM 서비스 계정 | 새 키 발급 → `supabase secrets set FCM_SERVICE_ACCOUNT="$(cat new.json)"` → push 재배포 → 이전 키 폐기 |
| Supabase publishable 키 | 새 키 발급 → 앱 `env.json` 교체 후 새 빌드 배포 → 최소 앱 버전 상향 → 이전 키 비활성화 |

## 6. 데이터·로그

- `work_logs`는 추가만 가능합니다. 트리거가 UPDATE·DELETE·TRUNCATE를 막습니다. 보관 기간 정책은 조직의 법무·개인정보 기준에 따라 정해야 합니다(**확인 필요**).
- 증빙 사진·서명은 비공개 버킷 `evidence`에 `{세션ID}/{파일}` 경로로 저장됩니다. 현재 앱에는 증빙 보기 화면이 없으므로 Dashboard → Storage → evidence에서 확인합니다(앱 내 보기는 로드맵).
- 개인정보: 이름·로그인 ID·작업 위치 좌표를 저장합니다. 로그·응답에 비밀번호·토큰을 남기지 않습니다(Edge는 내부 오류 상세를 응답에서 숨김).
- 백업·복구 범위는 Supabase 요금제에 따라 다릅니다(**확인 필요**: 사용 중인 요금제의 백업 주기). 기록을 내보내려면 SQL Editor에서 조회 결과를 CSV로 받으세요.

## 7. 로컬 검증(배포 전 회귀 확인)

```bash
bash supabase/tests/run.sh                                   # DB 277개
POSTGREST=/path/to/postgrest bash supabase/tests/run.sh      # + HTTP 통합 65개 = 342개
node --test supabase/functions/_tests/*.test.ts              # Edge 42개
python3 app/tool/xref_check.py                               # 앱↔서버 교차 검사
```
