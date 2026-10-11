import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/media_upload.dart';

void main() {
  const mb = 1024 * 1024;

  test('A small file goes in one piece', () {
    expect(MediaUpload.parts(800 * 1024), [(0, 800 * 1024)]);
  });

  test('A big file is split into 5 MB parts that cover every byte once', () {
    final size = 12 * mb + 123;
    final parts = MediaUpload.parts(size);
    expect(parts, [(0, 5 * mb), (5 * mb, 10 * mb), (10 * mb, size)]);
    // No gaps or overlaps, so the receiver can rebuild the exact file
    for (var i = 1; i < parts.length; i++) {
      expect(parts[i].$1, parts[i - 1].$2);
    }
    expect(parts.last.$2, size);
  });

  test('Voice messages and videos are recognised', () {
    expect(MediaUpload.isAudio('/cache/resq_voice_1.m4a'), isTrue);
    expect(MediaUpload.isVideo('/cache/VID_1.mp4'), isTrue);
    expect(MediaUpload.isVideo('/cache/IMG_1.jpg'), isFalse);
  });
}
