// path: app/test/models_test.dart
// 모델 변환(관대한 파싱) · 낙관적 반영 · RPC 결과 · 서버와 같은 체크 검증 규칙(공유 픽스처)
import 'dart:convert';
import 'dart:io';

import 'package:fieldsync/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SiteStatus / Role', () {
    test('DB 문자열 ↔ enum, 모르는 값은 대기중', () {
      for (final s in SiteStatus.values) {
        expect(SiteStatus.of(s.db), s);
      }
      expect(SiteStatus.of('???'), SiteStatus.pending);
      expect(SiteStatus.of(null), SiteStatus.pending);
    });
    test('점유 = 진행중·작업중·일시중단', () {
      expect(SiteStatus.values.where((s) => s.occupied), [SiteStatus.enRoute, SiteStatus.working, SiteStatus.paused]);
    });
    test('모르는 등급은 작업자(최소 권한)', () => expect(Role.of('root'), Role.worker));
  });

  group('Site', () {
    final j = {
      'id': 's1', 'group_id': 'g1', 'seq': 3, 'bunji': '성수동1가 685-12', 'jibun': '서울 성동구 성수동1가 685-12',
      'lat': 37.5445, 'lng': 127.0557, 'status': 'working', 'session_id': 'w1', 'occupant_id': 'u1',
      'occupant_name': '김작업', 'occupant_team': '1팀', 'started_at': '2026-09-23T01:02:03.000Z', 'urgent': true,
    };
    test('fromJson → toJson 왕복(UTC 시각 보존)', () {
      final s = Site.fromJson(j);
      expect(s.status, SiteStatus.working);
      expect(s.occupantName, '김작업');
      final back = s.toJson();
      expect(back['started_at'], '2026-09-23T01:02:03.000Z');
      expect(back['status'], 'working');
      expect(Site.fromJson(back).toJson(), back);
    });
    test('빈·잘못된 값에 관대(오프라인 캐시·Realtime 페이로드)', () {
      final s = Site.fromJson({'lat': '37.5', 'lng': null, 'seq': 'x'});
      expect(s.lat, 37.5);
      expect(s.lng, 0);
      expect(s.seq, 0);
      expect(s.status, SiteStatus.pending);
      expect(s.unit, '');
      expect(s.urgent, isFalse);
    });
    test('낙관적 반영: 작업 시작 시각 채움 · 대기 표시', () {
      final p = Site.fromJson({...j, 'status': 'en_route', 'started_at': null}).optimistic(status: SiteStatus.working);
      expect(p.status, SiteStatus.working);
      expect(p.startedAt, isNotNull);
      expect(p.pendingSync, isTrue);
      expect(p.occupantId, 'u1');
    });
    test('낙관적 반납: 점유 정보 제거', () {
      final p = Site.fromJson(j).optimistic(status: SiteStatus.pending, keepOccupant: false);
      expect([p.occupantId, p.occupantName, p.sessionId, p.startedAt], [null, null, null, null]);
    });
  });

  group('RpcResult', () {
    test('SITE_OCCUPIED: 점유자 이름·팀·시각·상태', () {
      final r = RpcResult.fromJson({
        'ok': false, 'code': 'SITE_OCCUPIED',
        'occupant': {'name': '이팀장', 'team': '2팀', 'since': '2026-09-23T00:30:00Z', 'status': 'paused'},
      });
      expect(r.ok, isFalse);
      expect(r.code, 'SITE_OCCUPIED');
      expect([r.occupantName, r.occupantTeam], ['이팀장', '2팀']);
      expect(r.occupantSince!.toUtc(), DateTime.utc(2026, 9, 23, 0, 30));
      expect(r.occupantStatus, SiteStatus.paused);
    });
    test('CHECKS_INCOMPLETE 누락 목록 · 재전송 표시', () {
      final r = RpcResult.fromJson({'ok': false, 'code': 'CHECKS_INCOMPLETE', 'missing': ['valve', 'photo'], 'replayed': true});
      expect(r.missing, ['valve', 'photo']);
      expect(r.replayed, isTrue);
    });
    test('빈 응답 → 실패·UNKNOWN(예외 없음)', () {
      final r = RpcResult.fromJson({});
      expect([r.ok, r.code, r.site, r.session], [false, 'UNKNOWN', null, null]);
    });
    test('성공: 현장·세션 포함', () {
      final r = RpcResult.fromJson({
        'ok': true, 'code': 'OK', 'site': {'id': 's1', 'status': 'en_route'},
        'session': {'id': 'w1', 'site_id': 's1', 'status': 'en_route', 'next_remind_at': '2026-09-23T02:00:00Z'},
      });
      expect(r.site!.status, SiteStatus.enRoute);
      expect(r.session!.active, isTrue);
      expect(r.session!.nextRemindAt, isNotNull);
    });
  });

  group('Settings', () {
    test('빈 값이면 서버 기본값과 동일', () {
      final s = Settings({});
      expect([s.workingFirstMin, s.workingRepeatMin, s.remindMax, s.escalateAt, s.enRouteAfterMin, s.pausedAfterMin], [90, 30, 8, 3, 45, 240]);
      expect([s.maxClaims, s.arriveRadiusM, s.undoWindowMin, s.minAppVersion], [3, 50, 5, '1.0.0']);
    });
    test('상태별 반복 간격(서버 run_reminders와 동일)', () {
      final s = Settings({'remind_working_repeat_min': 20, 'remind_en_route_after_min': 40, 'remind_paused_after_min': 120});
      expect(s.repeatFor('working'), const Duration(minutes: 20));
      expect(s.repeatFor('en_route'), const Duration(minutes: 40));
      expect(s.repeatFor('paused'), const Duration(minutes: 120));
    });
  });

  group('CheckItem / Template', () {
    test('toJson: select만 options, 빈 section 생략 → fromJson 왕복', () {
      final a = CheckItem(key: 'k', label: '수압', type: 'number', required: true, min: 0, max: 10, unit: 'bar');
      expect(a.toJson().containsKey('options'), isFalse);
      expect(a.toJson().containsKey('section'), isFalse);
      final b = CheckItem.fromJson(a.toJson());
      expect([b.key, b.type, b.required, b.min, b.max, b.unit], ['k', 'number', true, 0, 10, 'bar']);
      final c = CheckItem(key: 's', label: '상태', type: 'select', options: ['양호', '불량']);
      expect(CheckItem.fromJson(c.toJson()).options, ['양호', '불량']);
    });
    test('항목 없는 템플릿 → 누락 없음', () => expect(Template.fromJson({'id': 't', 'items': null}).missing({}), isEmpty));

    // 서버 private.missing_checks 결과로 만든 표(supabase/tests/80_check_parity.sh가 서버 쪽을 같은 표로 검증)
    final fx = jsonDecode(File('test/fixtures/check_parity.json').readAsStringSync()) as Map<String, dynamic>;
    final tpl = Template.fromJson({'id': 't', 'name': 't', 'items': fx['items']});
    for (final c in (fx['cases'] as List).cast<Map<String, dynamic>>()) {
      test('서버와 동일: ${c['name']}', () {
        expect(tpl.missing(Map<String, dynamic>.from(c['checks'] as Map)), List<String>.from(c['missing'] as List));
      });
    }
  });

  group('LogEntry', () {
    test('임베드된 작업자·현장 좌표', () {
      final e = LogEntry.fromJson({
        'id': 7, 'at': '2026-09-23T01:00:00Z', 'action': 'claim', 'ok': false, 'site_id': 's1',
        'actor': {'name': '박작업'}, 'site': {'bunji': '685-12', 'lat': 37.5, 'lng': 127.0}, 'lat': 37.501, 'lng': 127.0,
        'meta': {'code': 'SITE_OCCUPIED'},
      });
      expect([e.id, e.action, e.ok, e.actorName, e.siteBunji, e.siteLat], [7, 'claim', false, '박작업', '685-12', 37.5]);
      expect(e.meta['code'], 'SITE_OCCUPIED');
    });
  });
}
