#!/usr/bin/env python3
# path: supabase/tests/90_http_e2e.py
# 앱(app/lib/data/api.dart, state/app_state.dart)이 supabase_flutter로 보내는 요청을 같은 모양으로 실제 PostgREST에 보냄.
# 표준 라이브러리만 사용. 90_http_e2e.sh가 E2E_BASE·E2E_SECRET을 넘겨 실행. 출력: PASS:/FAIL: 줄
import base64, hashlib, hmac, json, os, sys, time, urllib.error, urllib.parse, urllib.request, uuid
from datetime import datetime, timedelta, timezone

BASE, SECRET = os.environ['E2E_BASE'], os.environ['E2E_SECRET']
U = lambda n: f'00000000-0000-4000-8000-e2e0000000{n}'
ADMIN, LEAD, W1, W2, W3, W4 = (f'00000000-0000-4000-8000-e2e00000000{i}' for i in (1, 2, 3, 4, 5, 7))
G, G_OTHER, G_DRAFT, S1, S2, S3 = U('d1'), U('d2'), U('d3'), U('f1'), U('f2'), U('f3')
fails = 0


def jwt(sub, role='authenticated'):
    b = lambda d: base64.urlsafe_b64encode(json.dumps(d, separators=(',', ':')).encode()).rstrip(b'=')
    head, body = b({'alg': 'HS256', 'typ': 'JWT'}), b({'sub': sub, 'role': role, 'aud': 'authenticated', 'exp': int(time.time()) + 3600})
    sig = base64.urlsafe_b64encode(hmac.new(SECRET.encode(), head + b'.' + body, hashlib.sha256).digest()).rstrip(b'=')
    return (head + b'.' + body + b'.' + sig).decode()


TOK = {u: jwt(u) for u in (ADMIN, LEAD, W1, W2, W3, W4)}


def http(method, path, who=None, body=None, headers=None):
    h = {'Content-Type': 'application/json', 'Accept': 'application/json', **(headers or {})}
    if who:
        h['Authorization'] = f'Bearer {TOK[who]}'
    data = None if body is None else json.dumps(body).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(BASE + path, data=data, method=method, headers=h), timeout=10) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw.decode(errors='replace')


def now_iso():  # Dart DateTime.now().toUtc().toIso8601String() 형식(마이크로초 + Z)
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%fZ')


def op(who, fn, site, **extra):  # AppState._op 과 같은 공통 인자
    body = {'p_site_id': site, 'p_op_id': str(uuid.uuid4()), 'p_client_at': now_iso(), 'p_lat': 37.6001, 'p_lng': 127.1001, **extra}
    return http('POST', f'/rpc/{fn}', who, body), body


def rpc(who, fn, **args):
    return http('POST', f'/rpc/{fn}', who, args)


def check(name, cond, detail=''):
    global fails
    if cond:
        print(f'PASS: {name}')
    else:
        fails += 1
        print(f'FAIL: {name} {detail}')


q = urllib.parse.quote
OBJ = {'Accept': 'application/vnd.pgrst.object+json'}  # .single() / .maybeSingle()

# ── 조회(RLS) ──
s, b = http('GET', '/sites?select=*', None)
check('E01 비로그인(anon)은 현장 조회 불가', s in (401, 403) or b == [], f'{s} {b}')
s, b = http('GET', f'/profiles?select=*&id=eq.{W1}', W1, headers=OBJ)
check('E02 me(): 본인 프로필 단건', s == 200 and b['role'] == 'worker' and b['name'] == 'E2E작업1', f'{s} {b}')
s, b = http('GET', '/settings?select=*&id=eq.1', W1, headers=OBJ)
check('E03 settings 단건(기본값)', s == 200 and b['max_claims_per_user'] == 3 and b['min_app_version'] == '1.0.0', f'{s} {b}')
s, b = http('GET', '/site_groups?select=*&archived=eq.false&order=work_date.desc', W1)
ids = {g['id'] for g in b} if s == 200 else set()
check('E04 작업자는 배포된 동선만 조회(초안 제외, 타팀 동선은 보기만 가능)', G in ids and G_OTHER in ids and G_DRAFT not in ids, f'{s} {ids}')
s, b = http('GET', f'/sites?select=*&group_id=eq.{G}&order=seq', W1)
check('E05 동선의 현장 목록(seq 순)', s == 200 and [x['id'] for x in b] == [S1, S2], f'{s} {b}')
(s, r), _ = op(W1, 'claim_site', S3)
check('E06 타팀 전용 동선 현장 맡기 → TEAM_MISMATCH', s == 200 and r['code'] == 'TEAM_MISMATCH', f'{s} {r}')
t0 = now_iso()

# ── 작업 흐름(앱 _op 인자 그대로) ──
(s, r), claim_body = op(W1, 'claim_site', S1)
check('E07 맡기 → 진행중', s == 200 and r['ok'] and r['site']['status'] == 'en_route' and r['session']['status'] == 'en_route', f'{s} {r}')
(s, r), _ = op(W2, 'claim_site', S1)
check('E08 타인 맡기 → SITE_OCCUPIED + 점유자 이름·팀', s == 200 and not r['ok'] and r['code'] == 'SITE_OCCUPIED'
      and r['occupant']['name'] == 'E2E작업1' and r['occupant']['team'] == 'E2E팀', f'{r}')
s, r2 = http('POST', '/rpc/claim_site', W1, claim_body)
check('E09 같은 op_id 재전송 → 같은 결과(replayed)', s == 200 and r2.get('replayed') is True and r2['site']['id'] == S1, f'{r2}')
(s, r), _ = op(W1, 'start_work', S1)
check('E10 작업 시작 → 작업중', r['ok'] and r['site']['status'] == 'working', f'{r}')
session_id = r['session']['id']
(s, r), _ = op(W1, 'save_checks', S1, p_checks={'w_meter': True})
check('E11 체크 임시 저장', r['ok'], f'{r}')
(s, r), _ = op(W1, 'pause_work', S1, p_reason_code='weather', p_memo=None)
check('E12 일시중단(사유 코드, 메모 null)', r['ok'] and r['site']['status'] == 'paused', f'{r}')
(s, r), _ = op(W1, 'resume_work', S1)
check('E13 재개 → 작업중', r['ok'] and r['site']['status'] == 'working', f'{r}')
(s, r), _ = op(W1, 'snooze_reminder', S1, p_minutes=30)
check('E14 알림 연기 30분', r['ok'], f'{r}')
(s, r), _ = op(W1, 'complete_work', S1, p_checks={'w_meter': True}, p_note=None)
check('E15 완료: 체크 누락 → CHECKS_INCOMPLETE + 누락 key', not r['ok'] and r['code'] == 'CHECKS_INCOMPLETE' and r['missing'] == ['s_hole'], f'{r}')
(s, r), _ = op(W1, 'complete_work', S1, p_checks={'w_meter': True, 's_hole': '양호'}, p_note=None)
check('E16 완료: 사진 없음 → PROOF_REQUIRED', not r['ok'] and r['code'] == 'PROOF_REQUIRED', f'{r}')

# 증빙 행(api.dart uploadEvidence 의 insert 키 그대로). Storage 객체 업로드는 Supabase Storage 서버 영역(로컬 미재현)
att = {'session_id': session_id, 'site_id': S1, 'kind': 'photo', 'path': f'{session_id}/{uuid.uuid4()}.jpg',
       'taken_at': now_iso(), 'lat': 37.6001, 'lng': 127.1001}
s, b = http('POST', '/attachments', W1, att)
check('E17 증빙 행 등록(컬럼 권한·RLS 통과)', s == 201, f'{s} {b}')
s, b = http('POST', '/attachments', W1, att)
check('E18 같은 증빙 재전송 → 409/23505(앱은 성공 처리)', s == 409 and b.get('code') == '23505', f'{s} {b}')
s, b = http('POST', '/attachments', W2, {**att, 'path': f'{session_id}/{uuid.uuid4()}.jpg'})
check('E19 남의 세션에 증빙 등록 불가', s in (401, 403), f'{s} {b}')
(s, r), _ = op(W1, 'complete_work', S1, p_checks={'w_meter': True, 's_hole': '양호'}, p_note='정상')
check('E20 완료 → 작업완료', r['ok'] and r['site']['status'] == 'done', f'{r}')
(s, r), _ = op(W1, 'undo_complete', S1)
check('E21 완료 취소(5분 내) → 작업중', r['ok'] and r['site']['status'] == 'working', f'{r}')
(s, r), _ = op(W1, 'complete_work', S1, p_checks={'w_meter': True, 's_hole': '양호'}, p_note=None)
check('E22 다시 완료', r['ok'] and r['site']['status'] == 'done', f'{r}')

# ── 조회: 로그 임베드·세션·델타 ──
path = '/work_logs?select=' + q('*, actor:profiles!actor_id(name), site:sites!site_id(bunji,lat,lng)') + f'&site_id=eq.{S1}&order=id.desc&limit=50'
s, b = http('GET', path, W1)
acts = [x['action'] for x in b] if s == 200 else []
check('E23 로그 임베드 조회(작업자 이름·현장 번지)', s == 200 and b and b[0]['actor']['name'] == 'E2E작업1'
      and b[0]['site']['bunji'] == '테스트동 1' and {'claim', 'start', 'pause', 'resume', 'complete', 'undo_complete'} <= set(acts), f'{s} {acts}')
s, b = http('GET', path, ADMIN)
rej = sorted((x['action'], x['actor']['name']) for x in b if x['ok'] is False) if s == 200 else []
check('E24 거절된 시도도 기록(관리자 조회: 타인 중복 맡기 + 누락 완료 2회)',
      rej == [('claim', 'E2E작업2'), ('complete', 'E2E작업1'), ('complete', 'E2E작업1')], f'{rej}')
s, b = http('GET', path, W1)
check('E24b 작업자는 자기 기록만 조회(타인 시도 비노출)', s == 200 and all(x['actor']['name'] == 'E2E작업1' for x in b), f'{s}')
s, b = http('GET', f'/work_sessions?select=*&user_id=eq.{W1}&status=in.(en_route,working,paused)', W1)
check('E25 내 활성 세션 조회(완료 후 0건)', s == 200 and b == [], f'{s} {b}')
s, b = http('GET', f'/sites?select=*&group_id=eq.{G}&updated_at=gt.{q(t0)}&order=seq', W1)
check('E26 델타 조회(updated_at > 시각) → 바뀐 현장만', s == 200 and [x['id'] for x in b] == [S1], f'{s} {[x["id"] for x in b] if s == 200 else b}')
s, b = http('GET', f'/sites?select=*&id=eq.{S1}', W2)
check('E27 Realtime용 비정규화: 완료 현장의 점유자명 유지', s == 200 and b[0]['occupant_name'] == 'E2E작업1' and b[0]['status'] == 'done', f'{b}')

# ── 권한: 컬럼 권한·RLS·RPC 권한 ──
new_site = {'group_id': G_DRAFT, 'seq': 1, 'bunji': '테스트동 9', 'jibun': '서울 테스트구 테스트동 9', 'road': None, 'unit': '',
            'lat': 37.6009, 'lng': 127.1009, 'b_code': '9999900000', 'jibun_key': '9999900000|0|9|0'}  # groups_page insertSite 키
s, b = http('POST', '/sites', W1, new_site)
check('E28 작업자는 현장 등록 불가(RLS)', s in (401, 403), f'{s} {b}')
s, b = http('POST', '/sites', LEAD, new_site)
check('E29 팀장은 초안 동선에 현장 등록', s == 201, f'{s} {b}')
s, b = http('POST', '/sites', LEAD, {**new_site, 'jibun_key': '9999900000|0|10|0', 'status': 'done'})
check('E30 상태 컬럼 직접 쓰기 차단(컬럼 권한)', s in (401, 403) and b.get('code') == '42501', f'{s} {b}')
s, b = http('POST', '/sites', LEAD, new_site)
check('E31 같은 지번+세부 중복 등록 → 409', s == 409, f'{s} {b}')
s, b = http('POST', '/sites', LEAD, {**new_site, 'group_id': G, 'jibun_key': '9999900000|0|11|0'})
check('E32 팀장은 배포된 동선에 현장 추가 불가', s in (401, 403), f'{s} {b}')
grp = {'name': 'E2E 초안(수정)', 'work_date': '2026-09-24', 'team_id': None, 'template_id': U('e1'), 'kakao_folder_url': None}
s, b = http('PATCH', f'/site_groups?id=eq.{G_DRAFT}&select=*', LEAD, grp, {**OBJ, 'Prefer': 'return=representation'})
check('E33 동선 수정(saveGroup: update().select().single())', s == 200 and b['name'] == 'E2E 초안(수정)', f'{s} {b}')
s, b = http('PATCH', f'/site_groups?id=eq.{G}&select=id', LEAD, {'name': '팀장이 바꾼 이름'}, {'Prefer': 'return=representation'})
check('E33b 배포된 동선은 팀장이 수정 불가(0행)', s == 200 and b == [], f'{s} {b}')
s, b = http('PATCH', f'/profiles?id=eq.{W1}', W1, {'lang': 'vi'})
check('E34 본인 언어 변경(컬럼 권한 lang)', s in (200, 204), f'{s} {b}')
s, b = http('PATCH', f'/profiles?id=eq.{W1}', W1, {'role': 'admin'})
check('E35 본인 등급 변경 차단', s in (401, 403), f'{s} {b}')
s, r = rpc(W1, 'publish_group', p_group_id=G_DRAFT, p_published=True, p_op_id=str(uuid.uuid4()), p_client_at=now_iso())
check('E36 작업자 배포 시도 → FORBIDDEN', s == 200 and r['code'] == 'FORBIDDEN', f'{r}')
s, r = rpc(ADMIN, 'publish_group', p_group_id=G_DRAFT, p_published=True, p_op_id=str(uuid.uuid4()), p_client_at=now_iso())
check('E37 관리자 배포', s == 200 and r['ok'], f'{r}')
s, b = rpc(W1, 'claim_push_batch', p_limit=10)
check('E38 앱 사용자는 푸시 선점 함수 호출 불가', s in (401, 403, 404), f'{s} {b}')
s, b = rpc(W1, 'claim_site', p_site_id=S2, p_op_id=str(uuid.uuid4()), p_bogus=1)
check('E39 정의되지 않은 인자 → 404 PGRST202(xref 검사가 막는 오류)', s == 404 and b.get('code') == 'PGRST202', f'{s} {b}')

# ── 긴급·통계·설정·기기 등록 ──
s, r = rpc(W1, 'send_urgent', p_message='누수', p_op_id=str(uuid.uuid4()), p_site_id=S2, p_client_at=now_iso())
check('E40 작업자 긴급 요청 → FORBIDDEN', r['code'] == 'FORBIDDEN', f'{r}')
s, r = rpc(LEAD, 'send_urgent', p_message='누수 발생, 즉시 확인', p_op_id=str(uuid.uuid4()), p_site_id=S2, p_client_at=now_iso())
urgent_id = (r.get('urgent_id') or (r.get('raw') or {}).get('urgent_id')) if isinstance(r, dict) else None
check('E41 팀장 긴급 요청(actions.dart doUrgent 인자)', s == 200 and r['ok'] and r['site']['urgent'] is True, f'{r}')
s, b = http('GET', '/urgent_requests?select=*&resolved_at=is.null&order=created_at.desc', W1)
open_ids = [x['id'] for x in b] if s == 200 else []
urgent_id = urgent_id or (open_ids[0] if open_ids else None)
check('E42 미해결 긴급 목록에 표시', urgent_id in open_ids, f'{s} {b}')
s, b = http('GET', '/notifications?select=*&order=created_at.desc&limit=100', W1)
mine = [n for n in b if n['kind'] == 'urgent' and n['data'].get('urgent_id') == urgent_id] if s == 200 else []
check('E43 수신자 알림함에 긴급 알림(본인 것만 조회)', len(mine) == 1 and all(n['user_id'] == W1 for n in b), f'{s} {len(mine)}')
s, x = http('PATCH', f'/notifications?id=in.({mine[0]["id"] if mine else 0})', W1, {'read_at': now_iso()})
check('E44 읽음 처리(컬럼 권한 read_at)', s in (200, 204), f'{s} {x}')
s, x = http('PATCH', f'/notifications?id=in.({mine[0]["id"] if mine else 0})', W1, {'title': 'x'})
check('E45 알림 내용 수정 차단', s in (401, 403), f'{s} {x}')
s, r = rpc(LEAD, 'resolve_urgent', p_urgent_id=urgent_id, p_op_id=str(uuid.uuid4()), p_client_at=now_iso())
check('E46 긴급 해결(actions.dart doUrgentTap 인자)', s == 200 and r['ok'] and r['site']['urgent'] is False, f'{r}')
s, b = http('GET', '/urgent_requests?select=*&resolved_at=is.null', W1)
check('E47 해결 후 미해결 목록에서 제외', s == 200 and urgent_id not in [x['id'] for x in b], f'{b}')

today = datetime.now(timezone(timedelta(hours=9))).date().isoformat()
s, b = rpc(ADMIN, 'get_stats', p_from=today, p_to=today, p_by='user')
row = next((x for x in b if x['name'] == 'E2E작업1'), None) if s == 200 else None
check('E48 통계(사람별): 맡기 1·완료 1·중복 시도 집계', row is not None and row['claimed'] >= 1 and row['completed'] >= 1, f'{s} {row}')
s, b = rpc(W1, 'get_stats', p_from=today, p_to=today, p_by='team')
check('E49 작업자 통계 조회 → 빈 결과(권한 없음)', s in (200, 403) and (s == 403 or b == []), f'{s} {b}')
policy = {'min_app_version': '1.0.0', 'remind_working_first_min': 90, 'remind_working_repeat_min': 30, 'remind_max': 8, 'escalate_at': 3,
          'remind_en_route_after_min': 45, 'remind_paused_after_min': 240, 'max_claims_per_user': 3, 'arrive_radius_m': 50,
          'undo_complete_window_min': 5}  # policy_page 전송 본문 그대로
s, r = rpc(ADMIN, 'update_settings', p_settings=policy, p_op_id=str(uuid.uuid4()))
check('E50 정책 저장(policy_page 본문)', s == 200 and r['ok'], f'{r}')
s, r = rpc(ADMIN, 'update_settings', p_settings={**policy, 'remind_working_first_min': 1}, p_op_id=str(uuid.uuid4()))
check('E51 범위 밖 정책 → INVALID_INPUT', s == 200 and r['code'] == 'INVALID_INPUT', f'{r}')
s, r = rpc(ADMIN, 'set_role_permission', p_role='worker', p_perm='urgent.send', p_granted=False, p_op_id=str(uuid.uuid4()))
check('E52 권한 매트릭스 변경(perms_page 인자)', s == 200 and r['ok'], f'{r}')
s, r = rpc(ADMIN, 'set_user_role', p_user_id=W2, p_role='worker', p_team_id=U('a1'), p_op_id=str(uuid.uuid4()))
check('E53 등급·팀 변경(users_page 인자)', s == 200 and r['ok'], f'{r}')
for who, token in ((W1, 'fcm-token-e2e-w1-ok'), (W2, 'fcm-token-e2e-w2-dead')):
    s, r = rpc(who, 'register_device', p_token=token, p_platform='android', p_notif_permission=True)
    check(f'E54 기기 등록({token})', s == 200 and r['ok'], f'{r}')

# 오프라인 대기열 재전송 순서: 맡기→시작이 한꺼번에 도착해도 순서대로 처리
(s, r1), _ = op(W2, 'claim_site', S2)
(s, r2), _ = op(W2, 'start_work', S2)
check('E55 대기열 순차 전송(맡기→시작)', r1['ok'] and r2['ok'] and r2['site']['status'] == 'working', f'{r1.get("code")} {r2.get("code")}')

print(f'E2E 결과: 실패 {fails}건')
sys.exit(1 if fails else 0)
