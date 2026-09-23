// path: app/lib/ui/signature_pad.dart
// 서명 패드(외부 패키지 없음): 손가락 획을 CustomPainter로 그리고 PNG로 내보냄. PNG 크기 수십 KB(추정)
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class SignatureController extends ChangeNotifier {
  final List<List<Offset>> strokes = [];
  bool get isEmpty => strokes.every((s) => s.length < 2);

  void begin(Offset p) {
    strokes.add([p]);
    notifyListeners();
  }

  void add(Offset p) {
    if (strokes.isEmpty) return;
    strokes.last.add(p);
    notifyListeners();
  }

  void clear() {
    strokes.clear();
    notifyListeners();
  }

  /// 흰 배경 PNG. O(점 개수)
  Future<Uint8List?> toPng(Size size) async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    _paint(canvas, strokes);
    final img = await rec.endRecording().toImage(size.width.round(), size.height.round());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }
}

void _paint(Canvas canvas, List<List<Offset>> strokes) {
  final p = Paint()
    ..color = Colors.black
    ..strokeWidth = 3
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.stroke;
  for (final s in strokes) {
    if (s.length < 2) continue;
    final path = Path()..moveTo(s.first.dx, s.first.dy);
    for (final o in s.skip(1)) {
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(path, p);
  }
}

class SignaturePad extends StatelessWidget {
  const SignaturePad({super.key, required this.controller, this.height = 180});
  final SignatureController controller;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.grey), borderRadius: BorderRadius.circular(8)),
        child: GestureDetector(
          onPanStart: (d) => controller.begin(d.localPosition),
          onPanUpdate: (d) => controller.add(d.localPosition),
          child: ListenableBuilder(
            listenable: controller,
            builder: (_, __) => CustomPaint(painter: _Painter(controller.strokes), size: Size.infinite),
          ),
        ),
      );
}

class _Painter extends CustomPainter {
  _Painter(this.strokes);
  final List<List<Offset>> strokes;

  @override
  void paint(Canvas canvas, Size size) => _paint(canvas, strokes);

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
