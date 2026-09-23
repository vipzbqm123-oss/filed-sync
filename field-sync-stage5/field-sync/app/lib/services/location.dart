// path: app/lib/services/location.dart
// 위치: 앱 사용 중에만(백그라운드 추적 없음 → 배터리·개인정보 보호). 20m 이동마다 갱신.
import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../state/app_state.dart';

class GeoLocator implements Locator {
  StreamSubscription<Position>? _sub;

  Future<bool> _ensure() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      return p == LocationPermission.whileInUse || p == LocationPermission.always;
    } catch (_) {
      return false; // 권한 요청 중복 등 플랫폼 오류 → 위치 없이 동작
    }
  }

  @override
  Future<void> start(void Function(double lat, double lng) onPosition) async {
    if (_sub != null || !await _ensure()) return;
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, distanceFilter: 20),
    ).listen((p) => onPosition(p.latitude, p.longitude), onError: (Object _) {});
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  @override
  Future<({double lat, double lng})?> current() async {
    if (!await _ensure()) return null;
    try {
      final p = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 10)));
      return (lat: p.latitude, lng: p.longitude);
    } catch (_) {
      final l = await Geolocator.getLastKnownPosition();
      return l == null ? null : (lat: l.latitude, lng: l.longitude);
    }
  }
}
