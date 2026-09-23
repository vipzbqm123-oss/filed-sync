-- path: supabase/tests/01_helpers_fixtures.sql
-- 테스트 헬퍼(단언·로그인) + 고정 픽스처. 표준 SQL/plpgsql만 사용(pgTAP 등 외부 의존성 없음).

create schema test;
grant usage on schema test to anon, authenticated, service_role;

create table test.ids (name text primary key, id uuid not null unique);
grant select on test.ids to anon, authenticated;
create function test.id(p text) returns uuid language sql stable as $$
  select id from test.ids where name = p
$$;

create function test.ok(p_cond boolean, p_name text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

create function test.eq(p_actual anyelement, p_expected anyelement, p_name text) returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL: % (expected %, got %)', p_name, p_expected, p_actual;
  end if;
  raise notice 'PASS: %', p_name;
end $$;

-- 예외 발생을 기대. p_state 지정 시 SQLSTATE까지 확인
create function test.raises(p_sql text, p_name text, p_state text default null) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if p_state is not null and sqlstate <> p_state then
      raise exception 'FAIL: % (expected SQLSTATE %, got % %)', p_name, p_state, sqlstate, sqlerrm;
    end if;
    raise notice 'PASS: %', p_name;
    return;
  end;
  raise exception 'FAIL: % (no exception)', p_name;
end $$;

-- PostgREST와 동일하게 역할·JWT 클레임을 트랜잭션 로컬로 설정
create function test.login(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create function test.code(p jsonb) returns text language sql immutable as $$ select p ->> 'code' $$;
create function test.op() returns uuid language sql volatile as $$ select gen_random_uuid() $$;

-- ───────── 픽스처 ─────────
insert into test.ids values
  ('T1', '00000000-0000-0000-0000-0000000000a1'), ('T2', '00000000-0000-0000-0000-0000000000a2'),
  ('A',  '00000000-0000-0000-0000-0000000000aa'),
  ('L1', '00000000-0000-0000-0000-0000000000b1'), ('L2', '00000000-0000-0000-0000-0000000000b2'),
  ('W1', '00000000-0000-0000-0000-0000000000c1'), ('W2', '00000000-0000-0000-0000-0000000000c2'),
  ('W3', '00000000-0000-0000-0000-0000000000c3'), ('W4', '00000000-0000-0000-0000-0000000000c4'),
  ('W5', '00000000-0000-0000-0000-0000000000c5'),
  ('TPL', '00000000-0000-0000-0000-0000000000e1'),
  ('G1', '00000000-0000-0000-0000-0000000000d1'), ('G2', '00000000-0000-0000-0000-0000000000d2'),
  ('G3', '00000000-0000-0000-0000-0000000000d3'),
  ('S1', '00000000-0000-0000-0000-0000000000f1'), ('S2', '00000000-0000-0000-0000-0000000000f2'),
  ('S3', '00000000-0000-0000-0000-0000000000f3'), ('S4', '00000000-0000-0000-0000-0000000000f4'),
  ('S5', '00000000-0000-0000-0000-0000000000f5'), ('S6', '00000000-0000-0000-0000-0000000000f6'),
  ('S7', '00000000-0000-0000-0000-0000000000f7');

insert into public.teams (id, name) values (test.id('T1'), '1팀'), (test.id('T2'), '2팀');

-- 신규 사용자 트리거(handle_new_user)가 profiles를 생성하는지도 함께 검증
insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data) values
  (test.id('A'),  'admin@staff.fieldsync.local', '{"name":"관리자"}', '{"role":"admin"}'),
  (test.id('L1'), 'lead1@staff.fieldsync.local', '{"name":"팀장1"}', format('{"role":"leader","team_id":"%s"}', test.id('T1'))::jsonb),
  (test.id('L2'), 'lead2@staff.fieldsync.local', '{"name":"팀장2"}', format('{"role":"leader","team_id":"%s"}', test.id('T2'))::jsonb),
  (test.id('W1'), 'kim@staff.fieldsync.local',   '{"name":"김철수"}', format('{"team_id":"%s"}', test.id('T1'))::jsonb),
  (test.id('W2'), 'lee@staff.fieldsync.local',   '{"name":"이영희","lang":"vi"}', format('{"team_id":"%s"}', test.id('T1'))::jsonb),
  (test.id('W3'), 'park@staff.fieldsync.local',  '{"name":"박민수"}', format('{"team_id":"%s"}', test.id('T2'))::jsonb),
  (test.id('W4'), 'gone@staff.fieldsync.local',  '{"name":"퇴사자"}', format('{"team_id":"%s"}', test.id('T1'))::jsonb),
  (test.id('W5'), 'solo@staff.fieldsync.local',  '{"name":"무소속"}', '{}');
update public.profiles set active = false where id = test.id('W4');

insert into public.check_templates (id, name, require_photo, items) values (test.id('TPL'), '테스트 템플릿', 1,
  '[{"key":"w_meter","section":"상수도","label":"계량기 확인","type":"bool","required":true},
    {"key":"w_leak","section":"상수도","label":"누수 여부","type":"select","options":["없음","있음"],"required":true},
    {"key":"w_read","section":"상수도","label":"지침","type":"number","min":0,"required":false},
    {"key":"s_hole","section":"하수도","label":"맨홀 상태","type":"select","options":["양호","파손","막힘"],"required":true},
    {"key":"s_back","section":"하수도","label":"역류 여부","type":"bool","required":true}]');

insert into public.site_groups (id, name, team_id, template_id, published, published_at) values
  (test.id('G1'), '9/23 성수 1구역', null,          test.id('TPL'), true,  now()),
  (test.id('G2'), '9/23 2팀 전용',   test.id('T2'), test.id('TPL'), true,  now()),
  (test.id('G3'), '9/24 초안',       null,          test.id('TPL'), false, null);

insert into public.sites (id, group_id, seq, bunji, jibun, lat, lng, b_code, jibun_key) values
  (test.id('S1'), test.id('G1'), 1, '성수동1가 685-12', '서울 성동구 성수동1가 685-12', 37.5446, 127.0557, '1120011400', '1120011400|0|685|12'),
  (test.id('S2'), test.id('G1'), 2, '성수동1가 686-3',  '서울 성동구 성수동1가 686-3',  37.5449, 127.0561, '1120011400', '1120011400|0|686|3'),
  (test.id('S3'), test.id('G1'), 3, '성수동1가 690-1',  '서울 성동구 성수동1가 690-1',  37.5452, 127.0570, '1120011400', '1120011400|0|690|1'),
  (test.id('S4'), test.id('G1'), 4, '성수동1가 684-7',  '서울 성동구 성수동1가 684-7',  37.5441, 127.0551, '1120011400', '1120011400|0|684|7'),
  (test.id('S5'), test.id('G1'), 5, '성수동1가 700',    '서울 성동구 성수동1가 700',    37.5460, 127.0580, '1120011400', '1120011400|0|700|0'),
  (test.id('S6'), test.id('G2'), 1, '성수동2가 300-1',  '서울 성동구 성수동2가 300-1',  37.5400, 127.0600, '1120011500', '1120011500|0|300|1'),
  (test.id('S7'), test.id('G3'), 1, '성수동2가 310',    '서울 성동구 성수동2가 310',    37.5410, 127.0610, '1120011500', '1120011500|0|310|0');

-- 현재 로그인 사용자로 사진 증빙 1장 등록 (RLS 적용)
create function test.photo(p_site uuid) returns void language sql as $$
  insert into public.attachments (session_id, site_id, kind, path)
  select session_id, id, 'photo', session_id || '/' || gen_random_uuid() || '.jpg'
    from public.sites where id = p_site
$$;
create function test.good() returns jsonb language sql immutable as $$
  select '{"w_meter":true,"w_leak":"없음","s_hole":"양호","s_back":false}'::jsonb
$$;
