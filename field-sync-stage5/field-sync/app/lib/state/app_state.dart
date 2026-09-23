// path: app/lib/state/app_state.dart
// 앱 전역 상태(ChangeNotifier, 외부 상태관리 패키지 없음).
// 흐름: 캐시 즉시 표시 → 서버 전체 조회 → Realtime 구독 → 재연결 시 updated_at 델타 → 아웃박스 전송.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session; // 작업 세션 모델(models.dart)과 이름 충돌 방지

import '../config.dart';
import '../core/i18n.dart';
import '../core/theme.dart';
import '../core/util.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../data/outbox.dart';

/// 알림·위치 서비스가 구현하는 인터페이스(테스트에서 대체 가능)
abstract class Reminders {
  Future<void> syncSession(Site site, Session s, Settings cfg);
  Future<void> cancelSession(String sessionId);
  Future<void> showOngoing(Site site);
  Future<void> cancelOngoing();
  Future<void> cancelAll();
  Future<void> test();
}

abstract class Locator {
  Future<void> start(void Function(double lat, double lng) onPosition);
  Future<void> stop();
  Future<({double lat, double lng})?> current();
}

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState(this.api);

  final Api api;
  Reminders? reminders;
  Locator? locator;
  late final Outbox outbox;
  late final JsonFile _cache, _prefs;
  late final String dataDir;

  final messenger = GlobalKey<ScaffoldMessengerState>();
  final navigator = GlobalKey<NavigatorState>();

  /// 알림 탭·도착 감지 등으로 열어야 할 현장(id). 홈 화면이 구독해 상세 시트를 연다
  final openSite = ValueNotifier<String?>(null);

  // ── 기기 설정 ──
  ThemeChoice theme = ThemeChoice.system;
  String lang = 'ko';
  bool batterySaver = false;
  double fontScale = 1.0;
  bool sortNearest = true;

  // ── 서버 상태 ──
  Profile? me;
  Settings settings = Settings(const {});
  Set<String> _perms = {};
  List<SiteGroup> groups = [];
  String? groupId;
  final Map<String, Site> sites = {};
  Map<String, Template> templates = {};
  final Map<String, Session> mySessions = {}; // key = siteId
  List<Urgent> urgent = [];
  int unread = 0;
  bool online = false;
  String? filter; // null=전체, SiteStatus.db, 'mine'
  double? myLat, myLng;

  DateTime? _lastSync;
  RealtimeChannel? _channel;
  final Map<String, DateTime> _prompted = {};

  // ───────── 파생 값 ─────────
  bool get loggedIn => api.uid != null && me != null;
  bool get isAdmin => me?.role == Role.admin;
  bool can(String perm) => isAdmin || _perms.contains(perm);
  bool get canManage => isAdmin || can('site.create') || can('site.edit') || can('template.edit');
  bool get updateRequired => versionLess(Config.appVersion, settings.minAppVersion);

  SiteGroup? get group => groups.where((g) => g.id == groupId).firstOrNull;
  Template? get template => group?.templateId == null ? null : templates[group!.templateId];

  List<Site> get groupSites => sites.values.where((s) => s.groupId == groupId && !s.archived).toList()
    ..sort((a, b) => a.seq.compareTo(b.seq));

  bool isMine(Site s) => s.occupantId != null && s.occupantId == me?.id;

  Map<String, int> get counts {
    final c = <String, int>{};
    for (final s in groupSites) {
      c[s.status.db] = (c[s.status.db] ?? 0) + 1;
      if (isMine(s) && s.status.occupied) c['mine'] = (c['mine'] ?? 0) + 1;
    }
    return c;
  }

  /// 필터·정렬 적용 목록: 내 점유 → (위치 있으면) 가까운 대기 → 나머지 순서(seq)
  List<Site> get listSites {
    final list = groupSites.where((s) => filter == null || (filter == 'mine' ? isMine(s) && s.status.occupied : s.status.db == filter)).toList();
    final mine = list.where((s) => isMine(s) && s.status.occupied).toList();
    var pending = list.where((s) => !mine.contains(s) && s.status == SiteStatus.pending).toList();
    final rest = list.where((s) => !mine.contains(s) && s.status != SiteStatus.pending).toList();
    if (sortNearest && myLat != null) pending = nearestOrder(pending, myLat!, myLng!);
    return [...mine, ...pending, ...rest];
  }

  /// 하단 고정 "현재 작업": 작업중 > 일시중단 > 진행중
  Site? get currentWork {
    for (final st in [SiteStatus.working, SiteStatus.paused, SiteStatus.enRoute]) {
      final s = groupSites.where((x) => isMine(x) && x.status == st).firstOrNull ??
          sites.values.where((x) => isMine(x) && x.status == st).firstOrNull;
      if (s != null) return s;
    }
    return null;
  }

  // ───────── 초기화 ─────────
  Future<void> init() async {
    dataDir = (await getApplicationSupportDirectory()).path;
    await Directory('$dataDir/pending').create(recursive: true);
    _cache = JsonFile('$dataDir/cache.json');
    _prefs = JsonFile('$dataDir/prefs.json');
    outbox = Outbox(store: JsonFile('$dataDir/outbox.json'), exec: _exec, onResult: _onResult, onDropped: _onDropped, onChanged: notifyListeners);
    await _loadPrefs();
    await outbox.load();
    WidgetsBinding.instance.addObserver(this);
    if (api.uid != null) {
      await _loadCache();
      unawaited(_goOnline());
    }
  }

  Future<void> _goOnline() async {
    await refreshAll();
    if (me == null) return;
    _subscribe();
    unawaited(outbox.flush());
    if (!batterySaver) unawaited(locator?.start(_onPosition));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!loggedIn) return;
    if (state == AppLifecycleState.resumed) {
      if (_channel == null) _subscribe();
      unawaited(_delta());
      unawaited(outbox.flush());
      if (!batterySaver) unawaited(locator?.start(_onPosition));
    } else if (state == AppLifecycleState.paused) {
      unawaited(locator?.stop());
      if (batterySaver) _unsubscribe(); // 절약 모드: 백그라운드에서 소켓 해제, 복귀 시 델타 조회
    }
  }

  // ───────── 인증 ─────────
  Future<String?> login(String loginId, String password) async {
    try {
      await api.signIn(loginId, password);
    } on AuthException {
      return tr('login.failed');
    } on TransientError {
      return tr('err.network');
    }
    await refreshAll();
    if (me == null) return online ? tr('login.inactive') : tr('err.network');
    _subscribe();
    unawaited(outbox.flush());
    if (!batterySaver) unawaited(locator?.start(_onPosition));
    return null;
  }

  Future<void> logout() async {
    _unsubscribe();
    await reminders?.cancelAll();
    await locator?.stop();
    await outbox.clear(); // 보내지 못한 요청이 다음 로그인 계정으로 전송되는 것 방지(설정 화면에서 사전 경고)
    try {
      await Directory('$dataDir/pending').delete(recursive: true); // 미전송 사진·서명
      await Directory('$dataDir/pending').create(recursive: true);
    } catch (_) {}
    try {
      await api.signOut();
    } catch (_) {/* 오프라인이어도 로컬 세션은 제거됨 */}
    me = null;
    sites.clear();
    mySessions.clear();
    groups = [];
    await _cache.write(null);
    notifyListeners();
  }

  // ───────── 조회·동기화 ─────────
  Future<void> refreshAll() async {
    try {
      final p = await api.me();
      if (p == null || !p.active) {
        online = true; // 서버 응답은 받음(계정 문제) → 네트워크 오류와 구분
        if (p != null) await logout();
        me = null;
        notifyListeners();
        return;
      }
      me = p;
      settings = await api.settings();
      final rp = await api.rolePerms();
      _perms = p.role == Role.admin ? {} : (rp[p.role.name] ?? {});
      groups = (await api.groups()).where((g) => g.published).toList();
      if (groupId == null || !groups.any((g) => g.id == groupId)) groupId = groups.firstOrNull?.id;
      templates = {for (final t in await api.templates()) t.id: t};
      await _loadSites(full: true);
      mySessions
        ..clear()
        ..addEntries((await api.mySessions()).map((s) => MapEntry(s.siteId, s)));
      urgent = await api.openUrgent();
      unread = (await api.notifications()).where((n) => n.readAt == null).length;
      online = true;
      unawaited(_saveCache());
      unawaited(_syncReminders());
    } on TransientError {
      online = false;
    } catch (e) {
      toast(errorText(e));
    }
    notifyListeners();
  }

  Future<void> _loadSites({required bool full}) async {
    final gid = groupId;
    if (gid == null) {
      sites.removeWhere((_, s) => !isMine(s));
      return;
    }
    final since = full ? null : _lastSync?.subtract(const Duration(seconds: 5)); // 이벤트 유실 보정 여유
    final list = await api.sites(gid, since: since);
    if (full) sites.removeWhere((_, s) => s.groupId == gid && !list.any((x) => x.id == s.id));
    for (final s in list) {
      _applySite(s);
    }
  }

  /// 재연결·앱 복귀 시 변경분만 조회
  Future<void> _delta() async {
    try {
      await _loadSites(full: false);
      mySessions
        ..clear()
        ..addEntries((await api.mySessions()).map((s) => MapEntry(s.siteId, s)));
      online = true;
      unawaited(_syncReminders());
      unawaited(_saveCache());
    } on TransientError {
      online = false;
    } catch (_) {}
    notifyListeners();
  }

  void _applySite(Site s) {
    sites[s.id] = s;
    if (s.updatedAt != null && (_lastSync == null || s.updatedAt!.isAfter(_lastSync!))) _lastSync = s.updatedAt;
  }

  Future<void> selectGroup(String id) async {
    groupId = id;
    _lastSync = null;
    notifyListeners();
    unawaited(_savePrefs());
    try {
      await _loadSites(full: true);
    } on TransientError {
      online = false;
    }
    notifyListeners();
  }

  // ───────── Realtime ─────────
  void _subscribe() {
    _unsubscribe();
    final uid = api.uid;
    if (uid == null) return;
    _channel = api.db
        .channel('fieldsync-$uid')
        .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'sites',
            callback: (p) {
              if (p.newRecord.isEmpty) return;
              final s = Site.fromJson(p.newRecord);
              final before = sites[s.id];
              _applySite(s);
              if (before != null && isMine(before) && !isMine(s)) _onLostSite(before);
              notifyListeners();
            })
        .onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'site_groups', callback: (_) => _reloadGroups())
        .onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'urgent_requests', callback: (_) => _reloadUrgent())
        .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'notifications',
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'user_id', value: uid),
            callback: (_) {
              unread++;
              notifyListeners();
            })
        .subscribe((status, error) {
      final wasOnline = online;
      online = status == RealtimeSubscribeStatus.subscribed;
      if (online && !wasOnline) {
        unawaited(_delta()); // 재연결 → 유실 보정
        unawaited(outbox.flush());
      }
      notifyListeners();
    });
  }

  void _unsubscribe() {
    final c = _channel;
    _channel = null;
    if (c != null) unawaited(api.db.removeChannel(c));
  }

  Future<void> _reloadGroups() async {
    try {
      groups = (await api.groups()).where((g) => g.published).toList();
      if (!groups.any((g) => g.id == groupId)) {
        groupId = groups.firstOrNull?.id;
        await _loadSites(full: true);
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _reloadUrgent() async {
    try {
      final before = urgent.map((u) => u.id).toSet();
      urgent = await api.openUrgent();
      final fresh = urgent.where((u) => !before.contains(u.id)).toList();
      if (fresh.isNotEmpty) toast('🚨 ${fresh.first.message}');
      notifyListeners();
    } catch (_) {}
  }

  /// 타인(팀장)이 내 점유를 해제한 경우: 알림 예약 취소 + 안내
  void _onLostSite(Site before) {
    final ses = mySessions.remove(before.id);
    if (ses != null) unawaited(reminders?.cancelSession(ses.id));
    unawaited(_syncOngoing());
    toast(tr('msg.lost_site', {'bunji': before.bunji}));
  }

  // ───────── 작업 조작(아웃박스 경유) ─────────
  Op _op(String fn, Site site, [Map<String, dynamic> extra = const {}]) {
    final id = uuidV4();
    return Op(id: id, fn: fn, siteId: site.id, createdAt: DateTime.now(), params: {
      'p_site_id': site.id,
      'p_op_id': id,
      'p_client_at': DateTime.now().toUtc().toIso8601String(),
      'p_lat': myLat,
      'p_lng': myLng,
      ...extra,
    });
  }

  /// 낙관적 반영 → 전송. 반환: 서버 결과(온라인) / null(대기열 보관)
  Future<RpcResult?> _act(String fn, Site site, {Map<String, dynamic> extra = const {}, SiteStatus? optimistic, bool release = false}) async {
    if (optimistic != null) {
      sites[site.id] = site.optimistic(status: optimistic, occupantId: me?.id, occupantName: me?.name, keepOccupant: !release);
      notifyListeners();
    }
    try {
      final r = await outbox.run(_op(fn, site, extra));
      if (r == null) toast(tr('msg.queued'));
      return r;
    } catch (_) {
      return null; // 제거된 요청은 _onDropped에서 안내·복구
    }
  }

  Future<void> claim(Site s) async {
    final r = await _act('claim_site', s, optimistic: SiteStatus.enRoute);
    if (r?.ok == true) toast(tr('msg.claimed', {'bunji': s.bunji}), action: tr('action.release'), onAction: () => release(s, tr('reason.undo')));
  }

  Future<void> start(Site s) => _act('start_work', s, optimistic: SiteStatus.working);
  Future<void> pause(Site s, String reasonCode, String memo) =>
      _act('pause_work', s, extra: {'p_reason_code': reasonCode, 'p_memo': memo.isEmpty ? null : memo}, optimistic: SiteStatus.paused);
  Future<void> resume(Site s) => _act('resume_work', s, optimistic: SiteStatus.working);
  Future<void> release(Site s, String reason) => _act('release_site', s, extra: {'p_reason': reason}, optimistic: SiteStatus.pending, release: true);
  Future<void> forceRelease(Site s, String reason) => _act('force_release', s, extra: {'p_reason': reason});
  Future<void> reopen(Site s, String reason) => _act('reopen_site', s, extra: {'p_reason': reason});
  Future<void> saveChecks(Site s, Map<String, dynamic> checks) => _act('save_checks', s, extra: {'p_checks': checks});
  Future<void> snooze(Site s, int minutes) => _act('snooze_reminder', s, extra: {'p_minutes': minutes});
  Future<void> undoComplete(Site s) => _act('undo_complete', s, optimistic: SiteStatus.working);

  Future<void> complete(Site s, Map<String, dynamic> checks, String note) async {
    final r = await _act('complete_work', s, extra: {'p_checks': checks, 'p_note': note.isEmpty ? null : note}, optimistic: SiteStatus.done);
    if (r?.ok == true) {
      toast(tr('msg.completed', {'bunji': s.bunji}), action: tr('action.undo_complete'), onAction: () => undoComplete(s));
    }
  }

  /// 증빙(사진·서명)을 앱 전용 폴더에 보관 후 업로드 요청 적재 — 오프라인에서도 유실 없음
  Future<void> addEvidence(Site s, String kind, List<int> bytes, {required String ext}) async {
    final id = uuidV4();
    final path = '$dataDir/pending/$id.$ext';
    await File(path).writeAsBytes(bytes, flush: true);
    final op = Op(id: id, kind: 'upload', fn: kind, siteId: s.id, file: path, createdAt: DateTime.now(), params: {'lat': myLat, 'lng': myLng, 'ext': ext});
    unawaited(outbox.run(op).then((_) {}, onError: (Object _) {})); // 실패 안내·복구는 _onDropped
  }

  int pendingEvidence(String siteId, String kind) => outbox.ops.where((o) => o.kind == 'upload' && o.siteId == siteId && o.fn == kind).length;

  Future<RpcResult?> _exec(Op op) async {
    if (op.kind != 'upload') return api.rpc(op.fn, op.params);
    final f = File(op.file ?? '');
    if (!await f.exists()) return null; // 이미 전송·정리됨
    final site = await api.site(op.siteId!); // 오프라인 맡기였다면 이 시점에 세션 id가 확정되어 있음
    final sid = site?.sessionId;
    if (site == null || sid == null || site.occupantId != api.uid) {
      await f.delete();
      throw ApiError(tr('err.upload_no_session'));
    }
    await api.uploadEvidence(
      sessionId: sid,
      siteId: site.id,
      kind: op.fn,
      name: '${op.id}.${op.params['ext'] ?? 'jpg'}',
      bytes: await f.readAsBytes(),
      takenAt: op.createdAt,
      lat: (op.params['lat'] as num?)?.toDouble(),
      lng: (op.params['lng'] as num?)?.toDouble(),
    );
    await f.delete();
    return null;
  }

  void _onResult(Op op, RpcResult? r) {
    if (r == null) return;
    final siteId = op.siteId;
    if (r.site != null) _applySite(r.site!);
    final ses = r.session;
    if (siteId != null && ses != null) {
      final site = sites[siteId];
      if (ses.active) {
        mySessions[siteId] = ses;
        if (site != null) unawaited(reminders?.syncSession(site, ses, settings));
      } else {
        mySessions.remove(siteId);
        unawaited(reminders?.cancelSession(ses.id));
      }
    }
    if (!r.ok) {
      toast(rejectText(r));
      if (siteId != null && r.site == null) unawaited(_refreshSite(siteId));
    }
    unawaited(_syncOngoing());
    unawaited(_saveCache());
    notifyListeners();
  }

  void _onDropped(Op op, Object e) {
    toast(errorText(e));
    if (op.siteId != null) unawaited(_refreshSite(op.siteId!));
  }

  Future<void> _refreshSite(String id) async {
    try {
      final s = await api.site(id);
      if (s != null) _applySite(s);
      notifyListeners();
    } catch (_) {}
  }

  // ───────── 알림 ─────────
  Future<void> _syncReminders() async {
    final r = reminders;
    if (r == null) return;
    for (final e in mySessions.entries) {
      final site = sites[e.key];
      if (site != null) await r.syncSession(site, e.value, settings);
    }
    await _syncOngoing();
  }

  Future<void> _syncOngoing() async {
    final w = currentWork;
    if (w != null && w.status == SiteStatus.working) {
      await reminders?.showOngoing(w);
    } else {
      await reminders?.cancelOngoing();
    }
  }

  /// 알림 탭/버튼 처리. payload = `site:<id>`
  void handleNotification(String? payload, String? actionId) {
    if (payload == null || !payload.startsWith('site:')) return;
    final id = payload.substring(5);
    final s = sites[id];
    if (actionId == 'snooze' && s != null) {
      unawaited(snooze(s, 30));
      return;
    }
    openSite.value = id;
  }

  // ───────── 위치(앱 사용 중에만) ─────────
  void _onPosition(double lat, double lng) {
    myLat = lat;
    myLng = lng;
    final radius = settings.arriveRadiusM.toDouble();
    final hasClaim = sites.values.any((s) => isMine(s) && s.status.occupied);
    for (final s in groupSites) {
      if (distanceM(lat, lng, s.lat, s.lng) > radius) continue;
      if (isMine(s) && s.status == SiteStatus.enRoute) {
        _prompt(s, 'start');
      } else if (!hasClaim && s.status == SiteStatus.pending) {
        _prompt(s, 'claim');
      }
    }
    notifyListeners();
  }

  /// 도착 확인창(자동 전환 없음). 같은 현장은 10분에 한 번만
  void _prompt(Site s, String kind) {
    final last = _prompted[s.id];
    if (last != null && DateTime.now().difference(last).inMinutes < 10) return;
    _prompted[s.id] = DateTime.now();
    final ctx = navigator.currentContext;
    if (ctx == null) return;
    showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(tr('arrive.title', {'bunji': s.bunji})),
        content: Text(tr(kind == 'start' ? 'arrive.start' : 'arrive.claim')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('common.later'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr(kind == 'start' ? 'action.start' : 'action.claim'))),
        ],
      ),
    ).then((ok) {
      if (ok == true) kind == 'start' ? start(s) : claim(s);
    });
  }

  Future<({double lat, double lng})?> locate() async {
    final p = await locator?.current();
    if (p != null) {
      myLat = p.lat;
      myLng = p.lng;
      notifyListeners();
    }
    return p;
  }

  // ───────── 설정 ─────────
  Future<void> setTheme(ThemeChoice t) async {
    theme = t;
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setLang(String l) async {
    lang = l;
    I18n.lang = l;
    notifyListeners();
    await _savePrefs();
    try {
      await api.setLang(l); // 서버 푸시 문구 언어
    } catch (_) {}
  }

  Future<void> setBatterySaver(bool v) async {
    batterySaver = v;
    if (v) {
      await locator?.stop();
    } else if (loggedIn) {
      await locator?.start(_onPosition);
    }
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setFontScale(double v) async {
    fontScale = v;
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setSortNearest(bool v) async {
    sortNearest = v;
    notifyListeners();
    await _savePrefs();
  }

  void clearUnread() {
    unread = 0;
    notifyListeners();
  }

  void setFilter(String? f) {
    filter = f;
    notifyListeners();
  }

  // ───────── 메시지 ─────────
  void toast(String msg, {String? action, VoidCallback? onAction}) {
    messenger.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: Duration(seconds: action == null ? 4 : 6),
        action: action == null ? null : SnackBarAction(label: action, onPressed: onAction ?? () {}),
      ));
  }

  /// 서버 거절 코드 → 사람 말 (예: "김철수님(1팀)이 09:12부터 작업중")
  String rejectText(RpcResult r) {
    if (r.code == 'SITE_OCCUPIED' && r.occupantName != null) {
      return tr('code.SITE_OCCUPIED', {
        'name': r.occupantName,
        'team': r.occupantTeam ?? '-',
        'time': r.occupantSince == null ? '' : fmtTime(r.occupantSince!),
        'status': StatusStyle.of(r.occupantStatus ?? SiteStatus.working).label,
      });
    }
    if (r.missing.isNotEmpty) {
      final labels = r.missing.map((k) => k == 'photo' ? tr('proof.photo') : k == 'signature' ? tr('proof.signature') : (template?.items.where((i) => i.key == k).firstOrNull?.label ?? k));
      return '${tr('code.${r.code}')}: ${labels.join(', ')}';
    }
    return tr('code.${r.code}');
  }

  String errorText(Object e) {
    if (e is TransientError) return tr('err.network');
    if (e is ApiError) return e.message;
    if (e is PostgrestException) return tr('err.server', {'msg': e.message});
    return tr('err.unknown');
  }

  // ───────── 캐시·환경설정 파일 ─────────
  Future<void> _saveCache() => _cache.write({
        'me': me?.toJson(),
        'settings': settings.j,
        'perms': _perms.toList(),
        'groups': groups.map((g) => g.toJson()).toList(),
        'group_id': groupId,
        'templates': templates.values.map((t) => t.toJson()).toList(),
        'sites': sites.values.map((s) => s.toJson()).toList(),
        'sessions': mySessions.values.map((s) => s.toJson()).toList(),
      });

  Future<void> _loadCache() async {
    final c = await _cache.read();
    if (c is! Map) return;
    Map<String, dynamic> m(Object? v) => Map<String, dynamic>.from(v as Map);
    if (c['me'] != null) me = Profile.fromJson(m(c['me']));
    settings = Settings(c['settings'] is Map ? m(c['settings']) : const {});
    _perms = {for (final p in (c['perms'] as List? ?? const [])) '$p'};
    groups = [for (final g in (c['groups'] as List? ?? const [])) SiteGroup.fromJson(m(g))];
    groupId = c['group_id'] as String? ?? groupId;
    templates = {for (final t in (c['templates'] as List? ?? const [])) '${m(t)['id']}': Template.fromJson(m(t))};
    for (final s in (c['sites'] as List? ?? const [])) {
      _applySite(Site.fromJson(m(s)));
    }
    for (final s in (c['sessions'] as List? ?? const [])) {
      final ses = Session.fromJson(m(s));
      mySessions[ses.siteId] = ses;
    }
    notifyListeners();
  }

  Future<void> _savePrefs() => _prefs.write({
        'theme': theme.name,
        'lang': lang,
        'battery_saver': batterySaver,
        'font_scale': fontScale,
        'sort_nearest': sortNearest,
        'group_id': groupId,
      });

  Future<void> _loadPrefs() async {
    final p = await _prefs.read();
    if (p is! Map) return;
    theme = ThemeChoice.values.where((t) => t.name == p['theme']).firstOrNull ?? ThemeChoice.system;
    lang = I18n.supported.contains(p['lang']) ? p['lang'] as String : 'ko';
    batterySaver = p['battery_saver'] == true;
    fontScale = (p['font_scale'] as num?)?.toDouble() ?? 1.0;
    sortNearest = p['sort_nearest'] != false;
    groupId = p['group_id'] as String?;
    I18n.lang = lang;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unsubscribe();
    super.dispose();
  }
}
