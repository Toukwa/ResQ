import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// A message a user can understand for any error, instead of the raw
/// "ClientException with SocketException: ..." text.
String friendlyError(Object error) {
  if (error is TimeoutException) return 'The connection is too slow and timed out. Please try again.';
  if (error is SocketException || error is HandshakeException) {
    return 'No internet connection. Check your connection and try again.';
  }
  if (error is http.ClientException) {
    final m = error.message.toLowerCase();
    if (m.contains('timed out') || m.contains('timeout')) return 'The connection is too slow and timed out. Please try again.';
    return 'No internet connection. Check your connection and try again.';
  }
  if (error is HttpException) return error.message;
  if (error is FormatException) return 'The server sent an unexpected reply. Please try again.';
  final text = '$error'
      .replaceFirst(RegExp(r'^(HttpException|Exception|ClientException)[^:]*:\s*'), '')
      .trim();
  // Anything that still reads like code
  if (text.contains('SocketException') || text.contains('Connection') && text.contains('errno')) {
    return 'No internet connection. Check your connection and try again.';
  }
  return text.isEmpty ? 'Something went wrong. Please try again.' : text;
}
