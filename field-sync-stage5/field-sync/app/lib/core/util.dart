// path: app/lib/core/util.dart
// 순수 함수 모음(의존성 0): UUID · 거리 · 동선 정렬 · 시간 표기 · 버전 비교.
import 'dart:math';

import '../data/models.dart';

final _rng = Random.secure();

/// RFC 4122 v4 UUID (멱등키 op_id 용). uuid 패키지 없이 16바이트 난수로 생성
String uuidV4() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// 두 좌표 사이 거리(m), Haversine. O(1)
double distanceM(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  double rad(double d) => d * pi / 180;
  final dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
  final a = sin(dLat / 2) * sin(dLat / 2) + cos(rad(lat1)) * cos(rad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
  return 2 * r * atan2(sqrt(a), sqrt(1 - a));
}

/// 현재 위치에서 시작하는 최근접 이웃 동선. O(n²) — n ≤ 300이면 9만 회(수 ms, 추정)
List<Site> nearestOrder(List<Site> sites, double lat, double lng) {
  final left = [...sites];
  final out = <Site>[];
  var cLat = lat, cLng = lng;
  while (left.isNotEmpty) {
    var bi = 0;
    var bd = double.infinity;
    for (var i = 0; i < left.length; i++) {
      final d = distanceM(cLat, cLng, left[i].lat, left[i].lng);
      if (d < bd) {
        bd = d;
        bi = i;
      }
    }
    final s = left.removeAt(bi);
    out.add(s);
    cLat = s.lat;
    cLng = s.lng;
  }
  return out;
}

/// 거리 표기: 950m / 1.2km
String fmtDistance(double m) => m < 999.5 ? '${m.round()}m' : '${(m / 1000).toStringAsFixed(1)}km'; // 999.6m → "1000m" 방지

/// 경과 시간 표기(언어별)
String fmtElapsed(Duration d, String lang) {
  final m = d.isNegative ? 0 : d.inMinutes;
  final h = m ~/ 60, mm = m % 60;
  switch (lang) {
    case 'en':
      return h > 0 ? '${h}h ${mm}m' : '${mm}m';
    case 'vi':
      return h > 0 ? '$h giờ $mm phút' : '$mm phút';
    default:
      return h > 0 ? '$h시간 $mm분' : '$mm분';
  }
}

String two(int v) => v.toString().padLeft(2, '0');

/// 로컬 시각 HH:mm
String fmtTime(DateTime t) => '${two(t.hour)}:${two(t.minute)}';

/// 날짜+시각 MM/dd HH:mm
String fmtDateTime(DateTime t) => '${two(t.month)}/${two(t.day)} ${fmtTime(t)}';

/// 작업중 타이머 HH:MM:SS
String fmtClock(Duration d) {
  final s = d.isNegative ? 0 : d.inSeconds;
  return '${two(s ~/ 3600)}:${two(s % 3600 ~/ 60)}:${two(s % 60)}';
}

/// 'a.b.c' 버전이 min보다 낮은가 (강제 업데이트 판단)
bool versionLess(String a, String min) {
  List<int> p(String v) => v.split('.').map((x) => int.tryParse(x) ?? 0).toList()..addAll([0, 0, 0]);
  final x = p(a), y = p(min);
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i] < y[i];
  }
  return false;
}

/// 알림 id: uuid 앞 6자리(최대 1,677만) × 16 + k → int32 범위 안. 충돌 확률 낮음(추정)
int notifBaseId(String uuid) => int.parse(uuid.replaceAll('-', '').substring(0, 6), radix: 16) * 16;
