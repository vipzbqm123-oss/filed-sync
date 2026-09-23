// path: app/lib/data/outbox.dart
// 오프라인 대기열(아웃박스): 모든 변경 요청을 멱등키(op_id)와 함께 FIFO로 보관 → 순서대로 전송.
// 네트워크 오류 = 재시도(5→10→20→40→60초), 업무 거절·입력 오류 = 해당 건만 제거하고 계속(서버 판단 우선).
// Flutter 의존 없는 순수 Dart → 단위 테스트 용이.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'models.dart';

class Op {
  Op({required this.id, required this.fn, required this.params, required this.createdAt, this.kind = 'rpc', this.siteId, this.file});

  final String id; // = p_op_id (서버 멱등키)
  final String kind; // rpc | upload
  final String fn; // RPC 이름 또는 업로드 종류(photo/signature)
  final Map<String, dynamic> params;
  final DateTime createdAt;
  final String? siteId, file; // file: 업로드할 로컬 파일 경로

  factory Op.fromJson(Map<String, dynamic> j) => Op(
        id: '${j['id']}',
        kind: '${j['kind'] ?? 'rpc'}',
        fn: '${j['fn']}',
        params: Map<String, dynamic>.from((j['params'] as Map?) ?? const {}),
        createdAt: DateTime.tryParse('${j['created_at']}') ?? DateTime.now(),
        siteId: j['site_id'] as String?,
        file: j['file'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'fn': fn,
        'params': params,
        'created_at': createdAt.toIso8601String(),
        'site_id': siteId,
        'file': file,
      };
}

/// 재시도하면 성공할 수 있는 오류(네트워크 단절·시간 초과 등)
class TransientError implements Exception {
  TransientError(this.cause);
  final Object cause;
  @override
  String toString() => 'TransientError($cause)';
}

/// JSON 파일 저장소. 임시 파일에 쓴 뒤 rename → 강제 종료돼도 파일이 깨지지 않음. 쓰기는 직렬화
class JsonFile {
  JsonFile(this.path);
  final String path;
  Future<void> _last = Future.value();

  Future<Object?> read() async {
    final f = File(path);
    if (!await f.exists()) return null;
    try {
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return null; // 손상 시 빈 상태로 시작
    }
  }

  Future<void> write(Object? value) => _last = _last.then((_) async {
        final tmp = File('$path.tmp');
        await tmp.writeAsString(jsonEncode(value), flush: true);
        await tmp.rename(path);
      });
}

typedef OpExecutor = Future<RpcResult?> Function(Op op);
typedef RetryScheduler = void Function(Duration delay, void Function() callback);

class Outbox {
  Outbox({required this.store, required this.exec, RetryScheduler? schedule, this.onResult, this.onDropped, this.onChanged})
      : _schedule = schedule ?? ((d, cb) => Timer(d, cb));

  final JsonFile store;
  final OpExecutor exec;
  final RetryScheduler _schedule;
  final void Function(Op op, RpcResult? result)? onResult;
  final void Function(Op op, Object error)? onDropped;
  final void Function()? onChanged;

  final List<Op> _ops = [];
  final Map<String, Completer<RpcResult?>> _waiters = {};
  bool _busy = false, _retryScheduled = false;
  int _backoffSec = 5;

  List<Op> get ops => List.unmodifiable(_ops);
  int get length => _ops.length;
  bool hasPendingFor(String siteId) => _ops.any((o) => o.siteId == siteId);

  Future<void> load() async {
    final v = await store.read();
    if (v is List) {
      _ops.addAll(v.whereType<Map>().map((e) => Op.fromJson(Map<String, dynamic>.from(e))));
    }
    onChanged?.call();
  }

  Future<void> _save() => store.write(_ops.map((o) => o.toJson()).toList());

  /// 로그아웃: 다른 계정으로 재전송되지 않도록 대기열 폐기. 대기 중인 호출자에는 null 통보
  Future<void> clear() async {
    _ops.clear();
    for (final c in _waiters.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _waiters.clear();
    await _save();
    onChanged?.call();
  }

  /// 적재 후 즉시 전송. 온라인이면 서버 결과, 네트워크 오류면 null(대기열 보관 — 복구 시 자동 전송)
  Future<RpcResult?> run(Op op) async {
    final c = Completer<RpcResult?>();
    _waiters[op.id] = c;
    _ops.add(op);
    await _save();
    onChanged?.call();
    unawaited(flush());
    return c.future;
  }

  /// 앞에서부터 순서대로 전송. 앱 복귀·실시간 재연결·재시도 타이머에서 호출. O(대기 건수)
  Future<void> flush() async {
    if (_busy) return;
    _busy = true;
    try {
      while (_ops.isNotEmpty) {
        final op = _ops.first;
        try {
          final r = await exec(op);
          _ops.removeAt(0);
          await _save();
          _backoffSec = 5;
          _waiters.remove(op.id)?.complete(r);
          onResult?.call(op, r);
        } on TransientError {
          for (final c in _waiters.values) {
            if (!c.isCompleted) c.complete(null); // 호출자에게 "대기열 보관" 즉시 통보
          }
          _waiters.clear();
          _scheduleRetry();
          break;
        } catch (e) {
          _ops.removeAt(0); // 재시도해도 같은 결과(입력 오류 등) → 제거
          await _save();
          final w = _waiters.remove(op.id);
          if (w != null) {
            w.completeError(e);
          }
          onDropped?.call(op, e);
        }
      }
    } finally {
      _busy = false;
      onChanged?.call();
    }
  }

  void _scheduleRetry() {
    if (_retryScheduled) return;
    _retryScheduled = true;
    final delay = Duration(seconds: _backoffSec);
    _backoffSec = min(_backoffSec * 2, 60);
    _schedule(delay, () {
      _retryScheduled = false;
      flush();
    });
  }
}
