// path: app/test/util_test.dart
// 순수 함수: UUID · 거리 · 동선 · 표기 · 버전 · 알림 id
import 'package:fieldsync/core/util.dart';
import 'package:fieldsync/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

Site _s(String id, double lat, double lng) => Site(id: id, groupId: 'g', bunji: id, jibun: id, lat: lat, lng: lng);

void main() {
  group('uuidV4', () {
    test('RFC 4122 v4 형식(버전 4 · 변형 8~b)', () {
      final re = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
      for (var i = 0; i < 1000; i++) {
        expect(re.hasMatch(uuidV4()), isTrue);
      }
    });
    test('1만 개 생성 시 중복 없음', () => expect({for (var i = 0; i < 10000; i++) uuidV4()}.length, 10000));
  });

  group('distanceM (Haversine)', () {
    test('같은 점 = 0', () => expect(distanceM(37.5, 127.0, 37.5, 127.0), 0));
    test('위도 1도 ≈ 111,195m', () => expect(distanceM(37, 127, 38, 127), closeTo(111195, 1)));
    test('서울시청→강남역 ≈ 8,778m', () => expect(distanceM(37.5663, 126.9779, 37.4979, 127.0276), closeTo(8778, 1)));
    test('대칭', () => expect(distanceM(37.1, 127.2, 37.3, 127.4), closeTo(distanceM(37.3, 127.4, 37.1, 127.2), 1e-6)));
  });

  group('nearestOrder', () {
    test('빈 목록 → 빈 목록', () => expect(nearestOrder([], 37, 127), isEmpty));
    test('현재 위치에서 가까운 순으로 연쇄', () {
      final a = _s('a', 37.0, 127.00), b = _s('b', 37.0, 127.01), c = _s('c', 37.0, 127.02);
      expect(nearestOrder([c, a, b], 37.0, 126.99).map((s) => s.id), ['a', 'b', 'c']);
      expect(nearestOrder([a, b, c], 37.0, 127.03).map((s) => s.id), ['c', 'b', 'a']);
    });
    test('입력 목록은 바꾸지 않음', () {
      final list = [_s('x', 37.2, 127), _s('y', 37.1, 127)];
      nearestOrder(list, 37, 127);
      expect(list.map((s) => s.id), ['x', 'y']);
    });
  });

  group('표기', () {
    test('fmtDistance', () {
      expect(fmtDistance(0), '0m');
      expect(fmtDistance(950.4), '950m');
      expect(fmtDistance(999.6), '1.0km');
      expect(fmtDistance(1234), '1.2km');
    });
    test('fmtElapsed 언어별 · 음수는 0', () {
      const d = Duration(minutes: 125);
      expect(fmtElapsed(d, 'ko'), '2시간 5분');
      expect(fmtElapsed(d, 'en'), '2h 5m');
      expect(fmtElapsed(d, 'vi'), '2 giờ 5 phút');
      expect(fmtElapsed(const Duration(minutes: 45), 'ko'), '45분');
      expect(fmtElapsed(const Duration(minutes: -3), 'en'), '0m');
    });
    test('fmtClock / fmtTime / fmtDateTime', () {
      expect(fmtClock(const Duration(seconds: 3725)), '01:02:05');
      expect(fmtClock(const Duration(seconds: -1)), '00:00:00');
      expect(fmtTime(DateTime(2026, 9, 23, 7, 5)), '07:05');
      expect(fmtDateTime(DateTime(2026, 9, 23, 7, 5)), '09/23 07:05');
    });
  });

  group('versionLess (강제 업데이트)', () {
    test('낮음/같음/높음', () {
      expect(versionLess('1.0.0', '1.0.1'), isTrue);
      expect(versionLess('1.2.0', '1.10.0'), isTrue); // 문자열 비교가 아닌 숫자 비교
      expect(versionLess('1.0.0', '1.0.0'), isFalse);
      expect(versionLess('2.0.0', '1.9.9'), isFalse);
    });
    test('자리 부족·비숫자는 0으로', () {
      expect(versionLess('1', '1.0.1'), isTrue);
      expect(versionLess('abc', '0.0.1'), isTrue);
      expect(versionLess('1.0', '1'), isFalse);
    });
  });

  group('notifBaseId', () {
    test('최댓값 + 15 도 int32 범위(알림 플러그인 요구)', () {
      expect(notifBaseId('ffffffff-0000-4000-8000-000000000000') + 15, lessThanOrEqualTo(2147483647));
      expect(notifBaseId('00000000-0000-4000-8000-000000000000'), 0);
    });
    test('16 간격 → 세션별 id 구간이 겹치지 않음', () {
      final a = notifBaseId('00000100-0000-4000-8000-000000000000'), b = notifBaseId('00000200-0000-4000-8000-000000000000');
      expect(b - a, 16);
    });
  });
}
