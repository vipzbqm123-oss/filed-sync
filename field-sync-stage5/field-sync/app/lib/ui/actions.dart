// path: app/lib/ui/actions.dart
// 화면 공용 작업 동작(사유 입력·오프라인 경고·외부 앱 열기). 상세 시트와 하단 작업 바에서 함께 사용.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/i18n.dart';
import '../core/util.dart';
import '../data/models.dart';
import 'complete_page.dart';
import 'widgets.dart';

/// 오프라인 맡기/바로 시작은 중복을 완전히 막을 수 없으므로 경고 후 진행(서버 선착순)
Future<bool> _offlineOk(BuildContext c) async {
  final st = AppScope.read(c);
  return st.online || await confirm(c, tr('offline.claim_title'), tr('offline.claim_body'));
}

Future<void> doClaim(BuildContext c, Site s) async {
  final st = AppScope.read(c);
  if (await _offlineOk(c)) await st.claim(s);
}

Future<void> doStart(BuildContext c, Site s) async {
  final st = AppScope.read(c);
  if (s.status == SiteStatus.pending && !await _offlineOk(c)) return;
  await st.start(s);
}

Future<void> doPause(BuildContext c, Site s) async {
  final st = AppScope.read(c);
  final code = await askChoice<String>(c, tr('pause.title'), {
    for (final k in ['absent', 'material', 'no_access', 'weather', 'other']) k: tr('pause.$k'),
  });
  if (code == null || !c.mounted) return;
  final memo = code == 'other' ? await askText(c, tr('pause.memo')) : '';
  if (memo == null) return;
  await st.pause(s, code, memo);
}

Future<void> doResume(BuildContext c, Site s) => AppScope.read(c).resume(s);

Future<void> doRelease(BuildContext c, Site s) async {
  final st = AppScope.read(c);
  final reason = await askText(c, tr('release.title'), hint: tr('release.hint'), initial: s.status == SiteStatus.enRoute ? tr('reason.changed') : '');
  if (reason != null) await st.release(s, reason);
}

Future<void> doForceRelease(BuildContext c, Site s) async {
  final st = AppScope.read(c);
  final reason = await askText(c, tr('force.title', {'name': s.occupantName ?? ''}), hint: tr('force.hint'));
  if (reason != null) await st.forceRelease(s, reason);
}

Future<void> doReopen(BuildContext c, Site s) async {
  final st = AppScope.read(c);
  final reason = await askText(c, tr('reopen.title'), hint: tr('reopen.hint'));
  if (reason != null) await st.reopen(s, reason);
}

Future<void> doComplete(BuildContext c, Site s) =>
    Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => CompletePage(siteId: s.id)));

/// 알림 연기: 10분/30분/1시간/직접(시·분). 서버 허용 범위 5~480분
Future<void> doSnooze(BuildContext c, Site s) async {
  final st = AppScope.read(c);
  final m = await askChoice<int>(c, tr('snooze.title'), {10: tr('snooze.m', {'n': 10}), 30: tr('snooze.m', {'n': 30}), 60: tr('snooze.h', {'n': 1}), -1: tr('snooze.custom')});
  if (m == null || !c.mounted) return;
  var minutes = m;
  if (m == -1) {
    if (!c.mounted) return;
    final t = await showTimePicker(context: c, initialTime: const TimeOfDay(hour: 1, minute: 0), helpText: tr('snooze.custom_help'));
    if (t == null) return;
    minutes = t.hour * 60 + t.minute;
  }
  await st.snooze(s, minutes.clamp(5, 480).toInt());
}

/// 긴급 요청(전원 푸시). 온라인 전용
Future<void> doUrgent(BuildContext c, {Site? site}) async {
  final st = AppScope.read(c);
  final msg = await askText(c, site == null ? tr('urgent.title') : tr('urgent.title_site', {'bunji': site.bunji}), hint: tr('urgent.hint'));
  if (msg == null) return;
  try {
    final r = await st.api.rpc('send_urgent', {'p_message': msg, 'p_op_id': uuidV4(), 'p_site_id': site?.id, 'p_client_at': DateTime.now().toUtc().toIso8601String()});
    st.toast(r.ok ? tr('urgent.sent') : st.rejectText(r));
  } catch (e) {
    st.toast(st.errorText(e));
  }
}

/// 긴급 배너 탭: 발송 권한자는 [현장 보기 | 해결 처리], 그 외는 현장 보기만. 해결 후 목록은 Realtime으로 갱신
Future<void> doUrgentTap(BuildContext c, Urgent u, void Function(String siteId) openSite) async {
  final st = AppScope.read(c);
  if (!st.can('urgent.send')) {
    if (u.siteId != null) openSite(u.siteId!);
    return;
  }
  final a = await askChoice<String>(c, u.message, {if (u.siteId != null) 'open': tr('urgent.open'), 'resolve': tr('urgent.resolve')});
  if (!c.mounted) return;
  if (a == 'open') openSite(u.siteId!);
  if (a != 'resolve') return;
  try {
    final r = await st.api.rpc('resolve_urgent', {'p_urgent_id': u.id, 'p_op_id': uuidV4(), 'p_client_at': DateTime.now().toUtc().toIso8601String()});
    st.toast(r.ok ? tr('urgent.resolved') : st.rejectText(r));
  } catch (e) {
    st.toast(st.errorText(e));
  }
}

/// 카카오맵 앱 길찾기(현재 위치 → 현장). 앱이 없으면 웹 링크로
Future<void> openRoute(BuildContext c, Site s) async {
  final st = AppScope.read(c);
  final me = await st.locate();
  final ep = '${s.lat},${s.lng}';
  final app = me == null ? 'kakaomap://look?p=$ep' : 'kakaomap://route?sp=${me.lat},${me.lng}&ep=$ep&by=car';
  final web = 'https://map.kakao.com/link/to/${Uri.encodeComponent(s.bunji)},$ep';
  await _launch(app, web);
}

Future<void> openKakaoView(Site s) =>
    _launch('kakaomap://look?p=${s.lat},${s.lng}', 'https://map.kakao.com/link/map/${Uri.encodeComponent(s.bunji)},${s.lat},${s.lng}');

Future<void> openUrl(String url) => _launch(url, null);

Future<void> _launch(String primary, String? fallback) async {
  try {
    if (await launchUrl(Uri.parse(primary), mode: LaunchMode.externalApplication)) return;
  } catch (_) {/* 앱 미설치 등 → 대체 링크 */}
  if (fallback != null) await launchUrl(Uri.parse(fallback), mode: LaunchMode.externalApplication);
}
