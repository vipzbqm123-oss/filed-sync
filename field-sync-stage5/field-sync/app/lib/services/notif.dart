// path: app/lib/services/notif.dart
// 알림 서비스: 로컬 리마인더(오프라인에서도 동작) · Android 상시 "작업중" 알림 · FCM 원격 푸시.
// 작업자 리마인더는 로컬 알림만 사용(서버는 에스컬레이션만 푸시) → 중복 알림 없음.
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../core/i18n.dart';
import '../core/util.dart';
import '../data/models.dart';
import '../state/app_state.dart';

class NotifService implements Reminders {
  NotifService({required this.onTap});

  /// payload(`site:<id>`)와 눌린 버튼 id(complete/snooze/null)
  final void Function(String? payload, String? actionId) onTap;
  final _plugin = FlutterLocalNotificationsPlugin();
  bool pushReady = false;
  static const _ongoingId = 1;
  static const _maxPerSession = 16; // iOS 대기 알림 64개 제한 고려(세션당 ≤16, 동시 점유 ≤3)

  Future<void> init() async {
    await _plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false, // 권한은 로그인 후 FCM requestPermission으로 한 번에 요청
          requestBadgePermission: false,
          requestSoundPermission: false,
          notificationCategories: [
            DarwinNotificationCategory('work', actions: [
              DarwinNotificationAction.plain('complete', tr('action.complete'), options: {DarwinNotificationActionOption.foreground}),
              DarwinNotificationAction.plain('snooze', tr('notif.snooze30'), options: {DarwinNotificationActionOption.foreground}),
            ]),
          ],
        ),
      ),
      onDidReceiveNotificationResponse: (r) => onTap(r.payload, r.actionId),
    );
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    for (final ch in [
      AndroidNotificationChannel('default', tr('channel.default'), importance: Importance.high),
      AndroidNotificationChannel('urgent', tr('channel.urgent'), importance: Importance.max),
      AndroidNotificationChannel('reminder', tr('channel.reminder'), importance: Importance.high),
      AndroidNotificationChannel('ongoing', tr('channel.ongoing'), importance: Importance.low, playSound: false, enableVibration: false),
    ]) {
      await android?.createNotificationChannel(ch);
    }
    final launch = await _plugin.getNotificationAppLaunchDetails(); // 알림으로 앱이 실행된 경우
    if (launch?.didNotificationLaunchApp == true) {
      onTap(launch!.notificationResponse?.payload, launch.notificationResponse?.actionId);
    }
  }

  // ───────── FCM ─────────
  /// Firebase 설정 파일(google-services.json / GoogleService-Info.plist)이 없으면 푸시만 비활성, 로컬 알림은 정상 동작
  Future<void> initPush(Future<void> Function(String token, String platform, bool permitted) register) async {
    try {
      await Firebase.initializeApp();
    } catch (_) {
      return;
    }
    final m = FirebaseMessaging.instance;
    final st = await m.requestPermission(); // iOS + Android 13+ 알림 권한
    final permitted = st.authorizationStatus == AuthorizationStatus.authorized || st.authorizationStatus == AuthorizationStatus.provisional;
    await m.setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true); // iOS 포그라운드 표시
    final platform = Platform.isIOS ? 'ios' : 'android';
    if (Platform.isIOS && await m.getAPNSToken() == null) {
      await Future<void>.delayed(const Duration(seconds: 3)); // APNs 토큰 준비 대기(없으면 getToken 실패)
    }
    try {
      final token = await m.getToken();
      if (token != null) await register(token, platform, permitted);
    } catch (_) {/* 다음 onTokenRefresh에서 재등록 */}
    m.onTokenRefresh.listen((t) => register(t, platform, permitted));
    FirebaseMessaging.onMessage.listen((msg) {
      if (Platform.isAndroid) _showRemote(msg); // Android 포그라운드는 자동 표시 안 됨 → 직접 표시
    });
    FirebaseMessaging.onMessageOpenedApp.listen((msg) => onTap(_payload(msg), null));
    final initial = await m.getInitialMessage();
    if (initial != null) onTap(_payload(initial), null);
    pushReady = true;
  }

  String? _payload(RemoteMessage m) => m.data['site_id'] == null ? null : 'site:${m.data['site_id']}';

  Future<void> _showRemote(RemoteMessage m) async {
    final n = m.notification;
    if (n == null) return;
    final urgent = m.data['kind'] == 'urgent';
    await _plugin.show(
      id: m.hashCode & 0x3fffffff,
      title: n.title,
      body: n.body,
      payload: _payload(m),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(urgent ? 'urgent' : 'default', tr(urgent ? 'channel.urgent' : 'channel.default'),
            importance: urgent ? Importance.max : Importance.high, priority: Priority.high),
      ),
    );
  }

  // ───────── 리마인더 (서버 next_remind_at 기준 동일 스케줄) ─────────
  NotificationDetails _reminderDetails() => NotificationDetails(
        android: AndroidNotificationDetails('reminder', tr('channel.reminder'),
            importance: Importance.high,
            priority: Priority.high,
            actions: [
              AndroidNotificationAction('complete', tr('action.complete'), showsUserInterface: true),
              AndroidNotificationAction('snooze', tr('notif.snooze30'), showsUserInterface: true),
            ]),
        iOS: const DarwinNotificationDetails(categoryIdentifier: 'work'),
      );

  /// next_remind_at부터 반복 간격으로 남은 회차만큼 예약. 정확 알람 권한 불필요(수 분 지연 허용)
  @override
  Future<void> syncSession(Site site, Session s, Settings cfg) async {
    await cancelSession(s.id);
    final next = s.nextRemindAt;
    if (next == null || !s.active) return;
    final repeat = cfg.repeatFor(s.status);
    final left = (cfg.remindMax - s.remindCount).clamp(0, _maxPerSession);
    final base = notifBaseId(s.id);
    final since = s.status == 'working' ? (s.startedAt ?? site.startedAt) : site.statusAt;
    final now = DateTime.now();
    try {
      for (var k = 0; k < left; k++) {
        final at = next.add(repeat * k);
        if (at.isBefore(now)) continue;
        await _plugin.zonedSchedule(
          id: base + k,
          title: tr('remind.title.${s.status}', {'bunji': site.bunji}),
          body: tr('remind.body.${s.status}', {'elapsed': fmtElapsed(at.difference(since ?? at), I18n.lang)}),
          scheduledDate: tz.TZDateTime.from(at.toUtc(), tz.UTC),
          notificationDetails: _reminderDetails(),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          payload: 'site:${site.id}',
        );
      }
    } catch (_) {
      // 알림 권한 거부·플랫폼 오류: 로컬 알림은 보조 수단(서버 에스컬레이션은 별도 동작)
    }
  }

  @override
  Future<void> cancelSession(String sessionId) async {
    final base = notifBaseId(sessionId);
    for (var k = 0; k < _maxPerSession; k++) {
      await _plugin.cancel(id: base + k);
    }
  }

  /// Android 상시 알림: 경과 시간(크로노미터) + [작업완료] 버튼. iOS는 앱 하단 작업 바로 대체
  @override
  Future<void> showOngoing(Site site) async {
    if (!Platform.isAndroid) return;
    try {
      await _plugin.show(
        id: _ongoingId,
        title: tr('ongoing.title', {'bunji': site.bunji}),
        body: tr('ongoing.body'),
        payload: 'site:${site.id}',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails('ongoing', tr('channel.ongoing'),
              importance: Importance.low,
              priority: Priority.low,
              ongoing: true,
              autoCancel: false,
              onlyAlertOnce: true,
              usesChronometer: true,
              showWhen: true,
              when: (site.startedAt ?? DateTime.now()).millisecondsSinceEpoch,
              actions: [AndroidNotificationAction('complete', tr('action.complete'), showsUserInterface: true)]),
        ),
      );
    } catch (_) {/* 권한 거부 시 무시(하단 작업 바가 대체) */}
  }

  @override
  Future<void> cancelOngoing() => _plugin.cancel(id: _ongoingId);

  @override
  Future<void> cancelAll() => _plugin.cancelAll();

  @override
  Future<void> test() => _plugin.show(
        id: 2,
        title: tr('settings.notif_test'),
        body: tr('settings.notif_test_body'),
        notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails('default', tr('channel.default'), importance: Importance.high, priority: Priority.high),
            iOS: const DarwinNotificationDetails()),
      );
}
