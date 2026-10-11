import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:video_compress/video_compress.dart';

import '../config.dart';
import 'firebase_rest.dart';

/// Getting evidence to responders quickly on a weak connection:
///  1. compress on the phone (photos and voice are compressed when captured; videos here),
///  2. upload big files in parts, retrying only a part that fails,
///  3. Cloudinary joins the parts back into one file, so staff always receive a
///     single complete photo, video or recording.
class MediaUpload {
  /// Cloudinary's smallest part size is 5 MB (only the last part may be smaller).
  static const chunkBytes = 5 * 1024 * 1024;
  static const _retries = 3;

  static bool isVideo(String path) =>
      const ['.mp4', '.mov', '.3gp', '.webm', '.mkv', '.m4v'].contains(p.extension(path).toLowerCase());

  static bool isAudio(String path) =>
      const ['.m4a', '.aac', '.mp3', '.wav', '.ogg'].contains(p.extension(path).toLowerCase());

  /// A smaller copy of a camera video (about 640p), or the original if compression
  /// isn't available here or doesn't help.
  static Future<File> compressVideo(File video) async {
    if (!Platform.isAndroid && !Platform.isIOS) return video;
    try {
      final info = await VideoCompress.compressVideo(
        video.path,
        quality: VideoQuality.MediumQuality,
        includeAudio: true,
        deleteOrigin: false,
      );
      final out = info?.file;
      if (out != null && await out.length() < await video.length()) return out;
    } catch (e) {
      debugPrint('Video compression failed, sending the original: $e');
    }
    return video;
  }

  /// The parts a file of [size] bytes is sent in, as [start, end) byte ranges.
  @visibleForTesting
  static List<(int, int)> parts(int size) => [
        for (var start = 0; start < size; start += chunkBytes) (start, min(start + chunkBytes, size)),
      ];

  /// Uploads [file] to Cloudinary and returns its link. Small files go in one request;
  /// bigger ones in parts that Cloudinary reassembles.
  static Future<String> upload(File file) async {
    final kind = isVideo(file.path) || isAudio(file.path) ? 'video' : 'image'; // Cloudinary keeps audio with video
    final uri = Uri.parse('https://api.cloudinary.com/v1_1/${AppConfig.cloudinaryCloudName}/$kind/upload');
    final publicId = '${FirebaseAuthRest.uid}_${DateTime.now().microsecondsSinceEpoch}';
    final size = await file.length();
    final name = p.basename(file.path);

    if (size <= chunkBytes) {
      final res = await _send(uri, publicId, await file.readAsBytes(), name);
      return res['secure_url'] as String;
    }

    // One id ties the parts together so Cloudinary can rebuild the file
    final uploadId = 'resq_${publicId}_${Random().nextInt(1 << 32)}';
    final raf = await file.open();
    try {
      Map<String, dynamic>? last;
      for (final (start, end) in parts(size)) {
        await raf.setPosition(start);
        final bytes = await raf.read(end - start);
        last = await _send(uri, publicId, bytes, name, headers: {
          'X-Unique-Upload-Id': uploadId,
          'Content-Range': 'bytes $start-${end - 1}/$size',
        });
      }
      return last!['secure_url'] as String;
    } finally {
      await raf.close();
    }
  }

  /// One request (a whole small file or one part), retried on a dropped connection.
  static Future<Map<String, dynamic>> _send(
    Uri uri,
    String publicId,
    List<int> bytes,
    String filename, {
    Map<String, String> headers = const {},
  }) async {
    for (var attempt = 1;; attempt++) {
      try {
        final req = http.MultipartRequest('POST', uri)
          ..headers.addAll(headers)
          ..fields['upload_preset'] = AppConfig.cloudinaryUploadPreset
          ..fields['public_id'] = publicId
          ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
        final res = await http.Response.fromStream(await req.send().timeout(const Duration(minutes: 2)));
        if (res.statusCode == 200) return jsonDecode(res.body) as Map<String, dynamic>;
        // A rejected file won't succeed on retry
        if (res.statusCode >= 400 && res.statusCode < 500) {
          throw HttpException('Evidence upload rejected (${res.statusCode}): ${res.body}');
        }
        if (attempt >= _retries) throw HttpException('Evidence upload failed (${res.statusCode})');
      } on HttpException {
        rethrow;
      } catch (e) {
        if (attempt >= _retries) throw HttpException('Evidence upload failed: $e');
      }
      await Future.delayed(Duration(seconds: attempt * 2)); // short wait before trying the part again
    }
  }
}
