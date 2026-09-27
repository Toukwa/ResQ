import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'dart:convert';
import '../config.dart';

/// Default timeout applied to all HTTP requests to prevent UI hangs
/// when the local Node.js server is unreachable or slow.
const Duration _kTimeout = Duration(seconds: 15);

class FirebaseService {
  static Uri _uri(String route) => Uri.parse('${AppConfig.apiBaseUrl}$route');

  static dynamic _decode(http.Response response) {
    final body = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        body is Map && body['error'] != null
            ? body['error'].toString()
            : 'Local server returned ${response.statusCode}.',
      );
    }
    return body;
  }

  static Future<Map<String, dynamic>?> login({
    required String email,
    required String password,
  }) async {
    final response = await http
        .post(
          _uri('/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'password': password}),
        )
        .timeout(_kTimeout);
    final decoded = _decode(response);
    return Map<String, dynamic>.from(decoded as Map);
  }

  static Future<Map<String, dynamic>?> verifyMfa({
    required int userId,
    required String otpCode,
  }) async {
    final response = await http
        .post(
          _uri('/verify-mfa'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'userId': userId, 'otpCode': otpCode}),
        )
        .timeout(_kTimeout);
    final decoded = _decode(response);
    return Map<String, dynamic>.from(decoded as Map);
  }

  /// Register this device as trusted so future logins skip MFA for 30 days.
  static Future<bool> trustDevice({
    required int userId,
    required String deviceToken,
    String deviceLabel = 'ResQ App',
  }) async {
    try {
      final response = await http
          .post(
            _uri('/trust-device'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'userId': userId,
              'deviceToken': deviceToken,
              'deviceLabel': deviceLabel,
            }),
          )
          .timeout(_kTimeout);
      final decoded = _decode(response);
      return decoded['success'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Check if this device is trusted for [userId]. Returns user data if trusted,
  /// or null if the device is not recognized / token is expired.
  static Future<Map<String, dynamic>?> checkTrustedDevice({
    required int userId,
    required String deviceToken,
  }) async {
    try {
      final response = await http
          .post(
            _uri('/check-trusted-device'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'userId': userId, 'deviceToken': deviceToken}),
          )
          .timeout(_kTimeout);
      final decoded = _decode(response);
      if (decoded['trusted'] == true && decoded['user'] != null) {
        return Map<String, dynamic>.from(decoded['user'] as Map);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> register({
    required String fullName,
    required String contactNo,
    required String email,
    required String password,
    String? fcmToken,
  }) async {
    final response = await http
        .post(
          _uri('/register'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'fullName': fullName,
            'contactNo': contactNo,
            'email': email,
            'password': password,
            'fcmToken': fcmToken,
          }),
        )
        .timeout(_kTimeout);
    _decode(response);
  }

  static Future<String?> uploadImage(File file) async {
    return null;
  }

  static Future<String> createIncident({
    required String citizenId,
    required String incidentType,
    required String description,
    required double latitude,
    required double longitude,
    File? image,
    List<File>? images,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/emergency-requests'))
      ..fields.addAll({
        'resident_id': citizenId,
        'type': incidentType,
        'description': description,
        'latitude': latitude.toString(),
        'longitude': longitude.toString(),
      });

    final allImages = <File>[];
    if (images != null && images.isNotEmpty) {
      allImages.addAll(images);
    } else if (image != null) {
      allImages.add(image);
    }

    for (var img in allImages) {
      request.files.add(
        await http.MultipartFile.fromPath(
          'images',
          img.path,
          filename: path.basename(img.path),
        ),
      );
    }

    final streamedResponse = await request.send().timeout(_kTimeout);
    final result = _decode(await http.Response.fromStream(streamedResponse));
    return result['emergency_id'].toString();
  }

  static Future<Map<String, dynamic>?> getEmergencyRequest(String reqId) async {
    try {
      final response = await http.get(_uri('/emergency-requests/$reqId')).timeout(_kTimeout);
      final body = _decode(response);
      if (body['success'] == true && body['data'] != null) {
        return Map<String, dynamic>.from(body['data']);
      }
    } catch (_) {}
    return null;
  }

  static Future<List<Map<String, dynamic>>> getCitizenEmergencyRequests(String citizenId) async {
    try {
      final response = await http.get(_uri('/citizen-emergency-requests/$citizenId')).timeout(_kTimeout);
      final body = _decode(response);
      if (body['success'] == true && body['data'] != null) {
        return List<Map<String, dynamic>>.from(body['data']);
      }
    } catch (_) {}
    return [];
  }

  static Future<List<dynamic>> getVehicles() async {
    final response =
        await http.get(_uri('/admin/vehicles-with-dept')).timeout(_kTimeout);
    final body = _decode(response);
    return List<dynamic>.from(body['data'] ?? []);
  }

  static Future<Map<String, dynamic>> getDashboardMetrics() async {
    final response =
        await http.get(_uri('/admin/dashboard-metrics')).timeout(_kTimeout);
    final body = _decode(response);
    return Map<String, dynamic>.from(body['data'] ?? {});
  }

  static Future<List<dynamic>> getActiveIncidents() async {
    final response = await http
        .get(_uri('/admin/active-incidents-list'))
        .timeout(_kTimeout);
    final body = _decode(response);
    return List<dynamic>.from(body['data'] ?? []);
  }

  static Future<List<dynamic>> getDispatchedVehicles(dynamic reqId) async {
    try {
      final response = await http
          .get(_uri('/citizen/dispatched-vehicles/$reqId'))
          .timeout(_kTimeout);
      final body = _decode(response);
      return List<dynamic>.from(body['data'] ?? []);
    } catch (_) {
      return [];
    }
  }

  static Future<List<dynamic>> searchIncidents(String query) async {
    final response = await http
        .get(
          _uri(
            '/admin/incidents/search?q=${Uri.encodeQueryComponent(query)}',
          ),
        )
        .timeout(_kTimeout);
    final body = _decode(response);
    return List<dynamic>.from(body['data'] ?? []);
  }

  static Future<String> dispatchVehicle({
    required int reqId,
    required int vehicleId,
    required int adminId,
    String? department,
  }) async {
    final payload = <String, dynamic>{
      'emergency_id': reqId,
      'vehicle_id': vehicleId,
      'admin_id': adminId,
    };
    if (department != null) payload['department'] = department;

    final response = await http
        .post(
          _uri('/admin/dispatch'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(payload),
        )
        .timeout(_kTimeout);
    final result = _decode(response);
    return 'Dispatch #${result['dispatch_id']} created successfully';
  }

  static Future<void> updateIncidentStatus({
    required int reqId,
    required String status,
    String? department,
  }) async {
    final payload = <String, dynamic>{
      'reqId': reqId,
      'status': status,
    };
    if (department != null) payload['department'] = department;

    final response = await http
        .post(
          _uri('/admin/update-status'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(payload),
        )
        .timeout(_kTimeout);
    _decode(response);
  }

  static DateTime getStartOfCurrentWeekMonday() {
    final now = DateTime.now();
    final daysFromMonday = now.weekday - 1;
    return DateTime(now.year, now.month, now.day - daysFromMonday, 0, 0, 0);
  }

  static Future<List<dynamic>> getActivityLogs({int limit = 50}) async {
    final url = _uri('/admin/activity-logs?limit=$limit');
    final response = await http.get(url).timeout(_kTimeout);
    final body = _decode(response);
    final rawList = List<dynamic>.from(body['data'] ?? []);
    final weekStart = getStartOfCurrentWeekMonday();

    return rawList.where((raw) {
      if (raw is! Map) return true;
      final tsStr = raw['timestamp']?.toString() ??
                    raw['created_at']?.toString() ??
                    raw['createdAt']?.toString() ?? '';
      if (tsStr.isEmpty) return true;
      final ts = DateTime.tryParse(tsStr)?.toLocal();
      if (ts == null) return true;
      return ts.isAfter(weekStart) || ts.isAtSameMomentAs(weekStart);
    }).toList();
  }

  static Future<List<int>?> downloadAuditLogPackageZip(String targetDate) async {
    try {
      final url = _uri('/admin/export-audit-logs-zip?date=$targetDate');
      final response = await http.get(url).timeout(const Duration(minutes: 2));
      if (response.statusCode >= 200 && response.statusCode < 300 && response.bodyBytes.isNotEmpty) {
        return response.bodyBytes;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<List<dynamic>> getMediaGallery() async {
    final url = _uri('/admin/media-gallery');
    final response = await http.get(url).timeout(const Duration(seconds: 10));
    final body = _decode(response);
    final rawList = List<dynamic>.from(body['data'] ?? []);
    final weekStart = getStartOfCurrentWeekMonday();

    return rawList.where((raw) {
      if (raw is! Map) return true;
      final tsStr = raw['uploadedAt']?.toString() ??
                    raw['uploaded_at']?.toString() ??
                    raw['SOS_timeStamp']?.toString() ??
                    raw['timestamp']?.toString() ??
                    raw['created_at']?.toString() ?? '';
      if (tsStr.isEmpty) return true;
      final ts = DateTime.tryParse(tsStr)?.toLocal();
      if (ts == null) return true;
      return ts.isAfter(weekStart) || ts.isAtSameMomentAs(weekStart);
    }).toList();
  }

  static Future<List<dynamic>> getMediaFilters() async {
    final url = _uri('/admin/media-filters');
    final response = await http.get(url).timeout(const Duration(seconds: 10));
    final body = _decode(response);
    return List<dynamic>.from(body['data'] ?? []);
  }

  static Future<Map<String, dynamic>?> getIncidentDispatch(int reqId) async {
    final url = _uri('/admin/incident-dispatch/$reqId');
    try {
      final response = await http.get(url).timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true ? body['data'] : null;
    } catch (e) {
      return null;
    }
  }

  // Notification API methods
  static Future<List<dynamic>> getNotifications(int userId) async {
    final url = _uri('/notifications/$userId');
    try {
      final response = await http.get(url).timeout(_kTimeout);
      final body = _decode(response);
      if (body['success'] == true && body['data'] != null) {
        final mappedData = (body['data'] as List).map((notification) {
          return {
            'notificationId': notification['notification_ID'],
            'recipientId': notification['recipient_ID'],
            'title': notification['title'],
            'message': notification['message'],
            'notificationType': notification['notification_type'],
            'reqId': notification['req_ID'],
            'dispId': notification['disp_ID'],
            'isRead': notification['is_read'] == 1,
            'readAt': notification['read_at'],
            'timestamp': notification['timestamp'] ?? notification['created_at'],
          };
        }).toList();
        return mappedData;
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  static Future<bool> addNotification({
    required int recipientId,
    required String message,
    String? title,
    int? reqId,
    int? dispId,
  }) async {
    final url = _uri('/notifications');
    try {
      final payload = {
        'recipientId': recipientId,
        'title': title,
        'message': message,
        'reqId': reqId,
        'dispId': dispId,
      };
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> markNotificationAsRead(int notificationId) async {
    final url = _uri('/notifications/$notificationId/read');
    try {
      final response = await http.put(url).timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> markAllNotificationsAsRead(int userId) async {
    final url = _uri('/notifications/$userId/read-all');
    try {
      final response = await http.put(url).timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true;
    } catch (e) {
      return false;
    }
  }

  static Future<int> getUnreadNotificationCount(int userId) async {
    final url = _uri('/notifications/$userId/unread-count');
    try {
      final response = await http.get(url).timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true ? body['count'] : 0;
    } catch (e) {
      return 0;
    }
  }

  // Management screen methods
  static Future<List<dynamic>> getAccounts() async {
    final url = _uri('/admin/accounts');
    try {
      final response = await http.get(url).timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true ? body['data'] : [];
    } catch (e) {
      return [];
    }
  }

  static Future<List<dynamic>> getVehiclesForManagement() async {
    final url = _uri('/admin/vehicles-manage');
    try {
      final response = await http.get(url).timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true ? body['data'] : [];
    } catch (e) {
      return [];
    }
  }

  static Future<List<dynamic>> getDepartments() async {
    final url = _uri('/admin/departments');
    try {
      final response = await http.get(url).timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true ? body['data'] : [];
    } catch (e) {
      return [];
    }
  }

  static Future<bool> createAccount(Map<String, dynamic> accountData) async {
    final url = _uri('/admin/accounts');
    try {
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(accountData),
          )
          .timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> updateAccount(
    int accountId,
    Map<String, dynamic> accountData,
  ) async {
    final url = _uri('/admin/accounts/$accountId');
    try {
      final response = await http
          .put(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(accountData),
          )
          .timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> deleteAccount(int accountId) async {
    final url = _uri('/admin/accounts/$accountId');
    try {
      final response = await http.delete(url).timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> createVehicle(Map<String, dynamic> vehicleData) async {
    final url = _uri('/admin/vehicles');
    try {
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(vehicleData),
          )
          .timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> updateVehicle(
    int vehicleId,
    Map<String, dynamic> vehicleData,
  ) async {
    final url = _uri('/admin/vehicles/$vehicleId');
    try {
      final response = await http
          .put(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(vehicleData),
          )
          .timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> deleteVehicle(int vehicleId) async {
    final url = _uri('/admin/vehicles/$vehicleId');
    try {
      final response = await http.delete(url).timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true;
    } catch (e) {
      return false;
    }
  }


  static Future<bool> updateDepartment(
    Map<String, dynamic> departmentData,
  ) async {
    final deptId = departmentData['dept_ID'] ?? departmentData['id'];
    final url = _uri('/admin/departments/$deptId');
    try {
      final response = await http
          .put(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(departmentData),
          )
          .timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true;
    } catch (e) {
      return false;
    }
  }

  // Dispatch status management
  static Future<bool> updateDispatchStatus(int dispId, String status) async {
    final url = _uri('/admin/dispatch/$dispId/status');
    try {
      final response = await http
          .put(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'status': status}),
          )
          .timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true;
    } catch (e) {
      return false;
    }
  }

  // FCM token management
  static Future<bool> updateFcmToken(int userId, String fcmToken) async {
    final url = _uri('/user/$userId/fcm-token');
    try {
      final response = await http
          .put(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'fcmToken': fcmToken}),
          )
          .timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true;
    } catch (e) {
      return false;
    }
  }

  // System logs
  static Future<List<dynamic>> getSystemLogs({
    int? userId,
    String? action,
    String? entityType,
    int limit = 100,
  }) async {
    final queryParams = <String, String>{
      if (userId != null) 'userId': userId.toString(),
      'action': ?action,
      'entityType': ?entityType,
      'limit': limit.toString(),
    };
    final url =
        _uri('/admin/system-logs').replace(queryParameters: queryParams);
    try {
      final response = await http.get(url).timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true ? body['data'] : [];
    } catch (e) {
      return [];
    }
  }

  static Future<bool> addSystemLog({
    required int userId,
    required String action,
    String? entityType,
    int? entityId,
    String? details,
    String? ipAddress,
  }) async {
    final url = _uri('/admin/system-logs');
    try {
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'userId': userId,
              'action': action,
              'entityType': entityType,
              'entityId': entityId,
              'details': details,
              'ipAddress': ipAddress,
            }),
          )
          .timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true;
    } catch (e) {
      return false;
    }
  }

  static Future<List<dynamic>> getSystemLogStats() async {
    final url = _uri('/admin/system-logs/stats');
    try {
      final response = await http.get(url).timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true ? body['data'] : [];
    } catch (e) {
      return [];
    }
  }

  // Enhanced system log methods
  static Future<List<dynamic>> getSystemLogsEnhanced({
    int? userId,
    String? action,
    String? entityType,
    int limit = 100,
    String? startDate,
    String? endDate,
  }) async {
    final queryParams = <String, String>{
      if (userId != null) 'userId': userId.toString(),
      'action': ?action,
      'entityType': ?entityType,
      'limit': limit.toString(),
      'startDate': ?startDate,
      'endDate': ?endDate,
    };
    final url =
        _uri('/admin/system-logs').replace(queryParameters: queryParams);
    try {
      final response = await http.get(url).timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true ? body['data'] : [];
    } catch (e) {
      return [];
    }
  }

  static Future<List<dynamic>> getSystemLogSummary() async {
    final url = _uri('/admin/system-logs/summary');
    try {
      final response = await http.get(url).timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true ? body['data'] : [];
    } catch (e) {
      return [];
    }
  }

  static Future<String> exportSystemLogs({
    String? startDate,
    String? endDate,
    String? entityType,
    String? action,
  }) async {
    final queryParams = <String, String>{
      'startDate': ?startDate,
      'endDate': ?endDate,
      'entityType': ?entityType,
      'action': ?action,
    };
    final url = _uri('/admin/system-logs/export')
        .replace(queryParameters: queryParams);
    try {
      final response = await http.get(url).timeout(_kTimeout);
      if (response.statusCode == 200) {
        return response.body; // CSV content
      } else {
        throw Exception('Failed to export system logs');
      }
    } catch (e) {
      rethrow;
    }
  }

  static Future<Map<String, dynamic>?> getUserSettings(int userId) async {
    final url = _uri('/user/$userId/settings');
    try {
      final response = await http.get(url).timeout(_kTimeout);
      final body = _decode(response);
      final rawSettings = body['settings'] ?? body['data'];
      if (body['success'] == true && rawSettings != null) {
        return Map<String, dynamic>.from(rawSettings as Map);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> updateUserSettings(int userId, Map<String, dynamic> settings) async {
    final url = _uri('/user/$userId/settings');
    try {
      final response = await http
          .put(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(settings),
          )
          .timeout(_kTimeout);
      final body = _decode(response);
      return body['success'] == true;
    } catch (_) {
      return false;
    }
  }

  static Future<({bool success, String message})> changeUserPassword({
    required int userId,
    required String currentPassword,
    required String newPassword,
  }) async {
    final url = _uri('/user/$userId/change-password');
    try {
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'currentPassword': currentPassword,
              'newPassword': newPassword,
            }),
          )
          .timeout(_kTimeout);
      final body = _decode(response);
      if (body['success'] == true) {
        return (success: true, message: body['message']?.toString() ?? 'Password changed successfully.');
      } else {
        return (success: false, message: body['error']?.toString() ?? 'Failed to change password.');
      }
    } catch (e) {
      return (success: false, message: e is HttpException ? e.message : 'Server error occurred.');
    }
  }

  static Future<Map<String, dynamic>?> getUserProfile(int userId) async {
    final url = _uri('/user/$userId/profile');
    try {
      final response = await http.get(url).timeout(_kTimeout);
      final body = _decode(response);
      if (body['success'] == true && body['user'] != null) {
        return Map<String, dynamic>.from(body['user'] as Map);
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
