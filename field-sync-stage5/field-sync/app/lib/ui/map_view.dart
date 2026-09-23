// path: app/lib/ui/map_view.dart
// 카카오맵: 상태별 마커(Poi) 동기화 · 작업중 마커 1Hz 깜빡임 · 내 위치 · 마커 탭 → 상세 시트.
// 마커 이미지는 위젯을 한 번만 이미지로 변환해 재사용(상태 5 × 내것 여부 × 깜빡임 2단계).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kakao_map_sdk/kakao_map_sdk.dart';

import '../core/theme.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'site_sheet.dart';
import 'widgets.dart';

class MapView extends StatefulWidget {
  const MapView({super.key});

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  KakaoMapController? _ctl;
  AppState? _st;
  final Map<String, Poi> _pois = {};
  final Map<String, String> _poiKey = {}; // siteId → 현재 스타일 키
  final Map<String, (double, double)> _poiPos = {};
  final Map<String, PoiStyle> _styles = {};
  Poi? _me;
  Timer? _blink;
  bool _phase = false, _syncing = false, _dirty = false;

  static const _maxBlink = 50; // 깜빡임 대상 상한(네이티브 호출 비용 제한)

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _st ??= AppScope.read(context);
  }

  @override
  void dispose() {
    _blink?.cancel();
    _st?.removeListener(_sync);
    super.dispose();
  }

  Future<void> _onReady(KakaoMapController c) async {
    _ctl = c;
    await _buildStyles();
    _st!.addListener(_sync);
    await _sync();
    _blink = Timer.periodic(const Duration(seconds: 1), (_) => _tickBlink());
  }

  Future<void> _buildStyles() async {
    for (final s in SiteStatus.values) {
      for (final mine in [false, true]) {
        for (final dim in (s == SiteStatus.working ? [false, true] : [false])) {
          final img = await KImage.fromWidget(_Marker(status: s, mine: mine, dim: dim), const Size(48, 56), context: mounted ? context : null);
          _styles[_key(s, mine, dim)] = PoiStyle(icon: img);
        }
      }
    }
    final meImg = await KImage.fromWidget(const _MeDot(), const Size(28, 28));
    _styles['me'] = PoiStyle(icon: meImg);
  }

  String _key(SiteStatus s, bool mine, bool dim) => '${s.db}|$mine|$dim';

  /// 상태 변경분만 네이티브에 반영(추가·스타일 변경·삭제). 호출 직렬화. O(현장 수)
  Future<void> _sync() async {
    final ctl = _ctl;
    final st = _st;
    if (ctl == null || st == null || !mounted) return;
    if (_syncing) {
      _dirty = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _dirty = false;
        final sites = {for (final s in st.groupSites) s.id: s};
        for (final id in _pois.keys.where((k) => !sites.containsKey(k)).toList()) {
          await ctl.labelLayer.removePoi(_pois.remove(id)!);
          _poiKey.remove(id);
          _poiPos.remove(id);
        }
        for (final s in sites.values) {
          final k = _key(s.status, st.isMine(s), false);
          final poi = _pois[s.id];
          if (poi != null && _poiPos[s.id] != (s.lat, s.lng)) {
            await ctl.labelLayer.removePoi(poi);
            _pois.remove(s.id);
          }
          if (_pois[s.id] == null) {
            _pois[s.id] = await ctl.labelLayer.addPoi(LatLng(s.lat, s.lng), style: _styles[k]!, id: s.id, onClick: () => showSiteSheet(context, s.id));
            _poiPos[s.id] = (s.lat, s.lng);
          } else if (_poiKey[s.id] != k) {
            await _pois[s.id]!.changeStyles(_styles[k]!);
          }
          _poiKey[s.id] = k;
        }
        await _syncMe(ctl, st);
      } while (_dirty && mounted);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _syncMe(KakaoMapController ctl, AppState st) async {
    if (st.myLat == null) return;
    final pos = LatLng(st.myLat!, st.myLng!);
    if (_me == null) {
      _me = await ctl.labelLayer.addPoi(pos, style: _styles['me']!, id: 'me', rank: 999);
    } else {
      await _me!.move(pos);
    }
  }

  /// 작업중 마커만 두 이미지 사이를 1초마다 전환. 절약 모드·동작 줄이기 설정 시 정지
  Future<void> _tickBlink() async {
    final st = _st;
    if (st == null || _syncing || !mounted || st.batterySaver || MediaQuery.of(context).disableAnimations) return;
    final working = st.groupSites.where((s) => s.status == SiteStatus.working && _pois[s.id] != null).take(_maxBlink);
    _phase = !_phase;
    for (final s in working) {
      await _pois[s.id]!.changeStyles(_styles[_key(s.status, st.isMine(s), _phase)]!);
      _poiKey[s.id] = _key(s.status, st.isMine(s), _phase);
    }
  }

  Future<void> _toMe() async {
    final p = await _st!.locate();
    if (p != null) await _ctl?.moveCamera(CameraUpdate.newCenterPosition(LatLng(p.lat, p.lng)));
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.read(context);
    final first = st.groupSites.firstOrNull;
    final center = first != null ? LatLng(first.lat, first.lng) : const LatLng(37.5665, 126.9780); // 기본: 서울시청
    return Stack(children: [
      KakaoMap(
        option: KakaoMapOption(position: center, zoomLevel: 16, mapType: MapType.normal),
        onMapReady: _onReady,
      ),
      Positioned(
        right: 12,
        bottom: 12,
        child: FloatingActionButton.small(heroTag: 'me', onPressed: _toMe, child: const Icon(Icons.my_location)),
      ),
    ]);
  }
}

/// 핀 모양 마커: 상태색 + 아이콘, 내 점유는 굵은 테두리
class _Marker extends StatelessWidget {
  const _Marker({required this.status, required this.mine, required this.dim});
  final SiteStatus status;
  final bool mine, dim;

  @override
  Widget build(BuildContext context) {
    final st = StatusStyle.of(status);
    return Opacity(
      opacity: dim ? 0.35 : 1,
      child: SizedBox(
        width: 48,
        height: 56,
        child: Stack(alignment: Alignment.topCenter, children: [
          Icon(Icons.location_on, size: 56, color: mine ? Colors.black : st.bg),
          Positioned(
            top: 6,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(color: st.bg, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
              child: Icon(st.icon, size: 16, color: st.fg),
            ),
          ),
        ]),
      ),
    );
  }
}

class _MeDot extends StatelessWidget {
  const _MeDot();

  @override
  Widget build(BuildContext context) => Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(color: Colors.blue, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
      );
}
