// path: app/test/outbox_test.dart
// 오프라인 대기열: FIFO · 네트워크 오류 재시도(지수 백오프) · 영구 오류 제거 · 파일 보존 · 손상 파일
import 'dart:async';
import 'dart:io';

import 'package:fieldsync/data/models.dart';
import 'package:fieldsync/data/outbox.dart';
import 'package:flutter_test/flutter_test.dart';

Op _op(String id) => Op(id: id, fn: 'claim_site', siteId: 's-$id', params: {'p_op_id': id}, createdAt: DateTime.utc(2026, 9, 23));
RpcResult _ok() => RpcResult.fromJson({'ok': true, 'code': 'OK'});

/// 실제 파일 IO가 끝날 때까지 조건 대기(최대 1초). 가짜 시계 없이 안정적으로 비동기 흐름 확인
Future<void> _until(bool Function() cond) async {
  for (var i = 0; i < 200 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory dir;
  late String path;
  final delays = <int>[];
  final retries = <void Function()>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('outbox_test');
    path = '${dir.path}/outbox.json';
    delays.clear();
    retries.clear();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Outbox make(OpExecutor exec, {List<String>? results, List<String>? dropped}) => Outbox(
        store: JsonFile(path),
        exec: exec,
        schedule: (d, cb) {
          delays.add(d.inSeconds);
          retries.add(cb);
        },
        onResult: (op, _) => results?.add(op.id),
        onDropped: (op, _) => dropped?.add(op.id),
      );

  test('온라인: 즉시 전송 → 서버 결과 반환 · 대기열 비움 · 파일 []', () async {
    final box = make((op) async => _ok());
    final r = await box.run(_op('a'));
    expect(r!.ok, isTrue);
    expect(box.length, 0);
    expect(await JsonFile(path).read(), isEmpty);
  });

  test('FIFO: 동시에 넣어도 넣은 순서대로 전송', () async {
    final sent = <String>[];
    final box = make((op) async {
      sent.add(op.id);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return _ok();
    });
    final fs = [box.run(_op('a')), box.run(_op('b')), box.run(_op('c'))];
    final rs = await Future.wait(fs);
    expect(sent, ['a', 'b', 'c']);
    expect(rs.every((r) => r!.ok), isTrue);
  });

  test('네트워크 오류: null 반환(대기 보관) → 재시도 성공 시 onResult', () async {
    var online = false;
    final results = <String>[];
    final box = make((op) async => online ? _ok() : throw TransientError('offline'), results: results);
    final ra = box.run(_op('a'));
    final rb = box.run(_op('b'));
    expect(await ra, isNull);
    expect(await rb, isNull); // 뒤에 쌓인 요청도 즉시 "대기" 통보
    expect(box.length, 2);
    expect(delays, [5]);
    online = true;
    retries.removeAt(0)();
    await _until(() => results.length == 2);
    expect(box.length, 0);
    expect(results, ['a', 'b']);
  });

  test('백오프 5→10→20→40→60→60초, 성공하면 5초로 초기화', () async {
    var fail = true;
    final box = make((op) async => fail ? throw TransientError('x') : _ok());
    await box.run(_op('a'));
    for (var i = 0; i < 5; i++) {
      retries.removeAt(0)();
      await _until(() => retries.isNotEmpty);
    }
    expect(delays, [5, 10, 20, 40, 60, 60]);
    fail = false;
    retries.removeAt(0)();
    await _until(() => box.length == 0);
    fail = true;
    await box.run(_op('b'));
    expect(delays.last, 5);
  });

  test('영구 오류: 해당 건만 제거(onDropped) · 호출자에 오류 · 다음 건 계속', () async {
    final dropped = <String>[], results = <String>[];
    final box = make((op) async => op.id == 'b' ? throw StateError('bad input') : _ok(), results: results, dropped: dropped);
    final fa = box.run(_op('a'));
    final fb = expectLater(box.run(_op('b')), throwsA(isA<StateError>())); // 오류 리스너를 먼저 연결
    final fc = box.run(_op('c'));
    expect((await fa)!.ok, isTrue);
    await fb;
    expect((await fc)!.ok, isTrue);
    expect(dropped, ['b']);
    expect(results, ['a', 'c']);
    expect(box.length, 0);
  });

  test('앱 재시작: 파일에서 대기열 복원(인자·현장 유지)', () async {
    final box1 = make((op) async => throw TransientError('offline'));
    await box1.run(Op(id: 'x', fn: 'pause_work', siteId: 's9', params: {'p_reason_code': 'weather'}, createdAt: DateTime.utc(2026)));
    final box2 = make((op) async => _ok());
    await box2.load();
    expect(box2.length, 1);
    expect(box2.hasPendingFor('s9'), isTrue);
    expect(box2.ops.first.fn, 'pause_work');
    expect(box2.ops.first.params['p_reason_code'], 'weather');
    await box2.flush();
    expect(box2.length, 0);
  });

  test('로그아웃(clear): 대기열·파일 비움 → 다음 계정으로 재전송되지 않음', () async {
    final box1 = make((op) async => throw TransientError('offline'));
    final pending = box1.run(_op('a'));
    expect(await pending, isNull);
    await box1.clear();
    expect(box1.length, 0);
    var calls = 0;
    final box2 = make((op) async {
      calls++;
      return _ok();
    });
    await box2.load();
    await box2.flush();
    expect([box2.length, calls], [0, 0]);
  });

  test('손상된 파일 → 빈 대기열로 시작(예외 없음)', () async {
    File(path).writeAsStringSync('{broken');
    final box = make((op) async => _ok());
    await box.load();
    expect(box.length, 0);
  });

  test('파일 없음 · 빈 대기열 flush → 전송 호출 없음', () async {
    var calls = 0;
    final box = make((op) async {
      calls++;
      return _ok();
    });
    await box.load();
    await box.flush();
    expect([box.length, calls], [0, 0]);
  });

  test('JsonFile: 연속 쓰기는 순서대로 직렬화 · 마지막 값 유지 · 임시 파일 없음', () async {
    final f = JsonFile(path);
    unawaited(f.write([1]));
    unawaited(f.write([1, 2]));
    await f.write([1, 2, 3]);
    expect(await f.read(), [1, 2, 3]);
    expect(File('$path.tmp').existsSync(), isFalse);
  });

  test('Op JSON 왕복 · 누락 필드 기본값', () {
    final o = Op(id: 'u', kind: 'upload', fn: 'photo', siteId: 's', file: '/p/u.jpg', params: {'ext': 'jpg'}, createdAt: DateTime.utc(2026, 1, 2));
    final b = Op.fromJson(o.toJson());
    expect([b.id, b.kind, b.fn, b.siteId, b.file, b.params['ext']], ['u', 'upload', 'photo', 's', '/p/u.jpg', 'jpg']);
    expect(b.createdAt, DateTime.utc(2026, 1, 2));
    final d = Op.fromJson({'id': 'v', 'fn': 'x'});
    expect([d.kind, d.params, d.siteId], ['rpc', <String, dynamic>{}, null]);
  });
}
