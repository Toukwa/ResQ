import 'dart:io';

import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'email_otp_service.dart';
import 'admin_data.dart';
import 'firebase_rest.dart';
import 'incident_data.dart';
import 'session_service.dart';
import 'vehicle_data.dart';

class FirebaseService {
  // ─── AUTH (Firebase Auth + Realtime Database) ───────────────────────────

  /// Profile stored at users/{uid}, in the shape the screens already expect.
  static Future<Map<String, dynamic>> _profile(String uid) async {
    final data = await Rtdb.get('users/$uid');
    if (data == null) throw const HttpException('Account profile not found.');
    final user = Map<String, dynamic>.from(data as Map);
    if (user['disabled'] == true) {
      await FirebaseAuthRest.signOut();
      throw const HttpException('This account has been disabled.');
    }
    user['uid'] = uid;
    return user;
  }

  static Future<void> _logEvent(Map<String, dynamic> user, String action, Map<String, dynamic> details) =>
      IncidentData.log(action, 'USER', user['id'], details);
  static Future<Map<String, dynamic>?> login({
    required String email,
    required String password,
  }) async {
    final uid = await FirebaseAuthRest.signIn(email, password);
    final user = await _profile(uid);

    final settings = await Rtdb.get('user_settings/$uid');
    final mfaSetting = settings is Map ? settings['mfa_enabled'] : null;
    final mfaEnabled = mfaSetting != false && mfaSetting != 0;

    if (mfaEnabled && await _isTrustedDevice(uid, _int(user['id']))) {
      await _logEvent(user, 'LOGIN_TRUSTED_DEVICE', {'email': user['email'], 'mfa': 'skipped_trusted_device'});
      return {'success': true, 'mfaRequired': false, 'user': user};
    }

    if (mfaEnabled) {
      await EmailOtpService.sendCode(email: user['email'], userName: user['fullName'] ?? 'User');
      return {
        'success': true,
        'mfaRequired': true,
        'userId': user['id'],
        'targetEmail': user['email'],
        'maskedEmail': EmailOtpService.maskEmail(user['email']),
      };
    }

    await _logEvent(user, 'LOGIN', {'email': user['email'], 'mfa': false});
    return {'success': true, 'mfaRequired': false, 'user': user};
  }

  static Future<Map<String, dynamic>?> verifyMfa({
    required int userId,
    required String otpCode,
  }) async {
    final ok = await EmailOtpService.verify(otpCode);
    if (!ok) return {'success': false, 'error': 'Incorrect 6-digit verification code'};
    final user = await _profile(FirebaseAuthRest.uid!);
    await _logEvent(user, 'LOGIN_MFA_VERIFIED', {'email': user['email'], 'mfa': true});
    return {'success': true, 'user': user};
  }

  static String _hashToken(String token) => sha256.convert(utf8.encode(token)).toString();

  static int? _int(dynamic v) => v == null ? null : int.tryParse(v.toString());

  /// True if the user ticked "Remember this device" here within the last 30 days.
  static Future<bool> _isTrustedDevice(String uid, int? userId) async {
    if (userId == null) return false;
    final token = await SessionService.getDeviceToken(userId);
    if (token == null) return false;
    try {
      final device = await Rtdb.get('trusted_devices/$uid/${_hashToken(token)}');
      return device != null && DateTime.now().millisecondsSinceEpoch <= (device['expiresAt'] as int);
    } catch (_) {
      return false;
    }
  }

  /// Register this device as trusted so future logins skip MFA for 30 days.
  static Future<bool> trustDevice({
    required int userId,
    required String deviceToken,
    String deviceLabel = 'ResQ App',
  }) async {
    try {
      await Rtdb.set('trusted_devices/${FirebaseAuthRest.uid}/${_hashToken(deviceToken)}', {
        'label': deviceLabel,
        'expiresAt': DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Returns the user if this device holds a saved login and is still trusted.
  static Future<Map<String, dynamic>?> checkTrustedDevice({
    required int userId,
    required String deviceToken,
  }) async {
    try {
      final uid = await FirebaseAuthRest.restore();
      if (uid == null) return null;
      final device = await Rtdb.get('trusted_devices/$uid/${_hashToken(deviceToken)}');
      if (device == null || DateTime.now().millisecondsSinceEpoch > (device['expiresAt'] as int)) {
        return null;
      }
      final user = await _profile(uid);
      await _logEvent(user, 'LOGIN_TRUSTED_DEVICE', {'email': user['email'], 'mfa': 'skipped_trusted_device'});
      return user;
    } catch (_) {
      return null;
    }
  }

  /// Signs out. Remembered devices stay trusted until they expire.
  static Future<void> signOut() => FirebaseAuthRest.signOut();

  static Future<void> sendPasswordReset(String email) => FirebaseAuthRest.sendPasswordReset(email);

  static Future<void> register({
    required String fullName,
    required String contactNo,
    required String email,
    required String password,
    String? fcmToken,
  }) async {
    final uid = await FirebaseAuthRest.signUp(email, password);
    final id = await Rtdb.nextId('counters/users');
    final user = {
      'id': id,
      'fullName': fullName.trim(),
      'email': email.trim().toLowerCase(),
      'contactNo': contactNo.trim(),
      'role': 'Citizen',
      'createdAt': {'.sv': 'timestamp'},
    };
    await Rtdb.set('users/$uid', user);
    await Rtdb.set('user_ids/$id', uid);
    await _logEvent(user, 'REGISTER', {'email': email});
    await FirebaseAuthRest.signOut();
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
  }) {
    final allImages = <File>[
      if (images != null && images.isNotEmpty) ...images else ?image,
    ];
    return IncidentData.createIncident(
      citizenId: citizenId,
      incidentType: incidentType,
      description: description,
      latitude: latitude,
      longitude: longitude,
      images: allImages,
    );
  }

  static Future<Map<String, dynamic>?> getEmergencyRequest(String reqId) async {
    try {
      return await IncidentData.getIncident(reqId);
    } catch (_) {
      return null;
    }
  }

  static Future<List<Map<String, dynamic>>> getCitizenEmergencyRequests(String citizenId) async {
    try {
      return await IncidentData.getMyIncidents();
    } catch (_) {
      return [];
    }
  }

  static Future<List<dynamic>> getVehicles() => VehicleData.getVehicles().then(_loose);

  static Future<Map<String, dynamic>> getDashboardMetrics() => AdminData.dashboardMetrics();
  static Future<List<dynamic>> getActiveIncidents() => IncidentData.getAllIncidents().then(_loose);

  static Future<List<dynamic>> getDispatchedVehicles(dynamic reqId) async {
    try {
      return _loose(await IncidentData.getDispatchedVehicles(int.parse(reqId.toString())));
    } catch (_) {
      return [];
    }
  }

  static Future<List<dynamic>> searchIncidents(String query) => IncidentData.searchIncidents(query).then(_loose);

  static Future<String> dispatchVehicle({
    required int reqId,
    required int vehicleId,
    required int adminId,
    String? department,
  }) async {
    final id = await IncidentData.dispatchVehicle(
      reqId: reqId,
      vehicleId: vehicleId,
      adminId: adminId,
      department: department,
    );
    return 'Dispatch #$id created successfully';
  }

  static Future<void> updateIncidentStatus({
    required int reqId,
    required String status,
    String? department,
  }) => IncidentData.updateIncidentStatus(reqId, status, department);

  /// Screens were written against JSON lists (`List<dynamic>`) and call things like
  /// firstWhere(orElse: ...) that fail on a strictly typed list, so hand them loose lists.
  static List<dynamic> _loose(Iterable<dynamic> items) => List<dynamic>.from(items);

  static DateTime getStartOfCurrentWeekMonday() {
    final now = DateTime.now();
    final daysFromMonday = now.weekday - 1;
    return DateTime(now.year, now.month, now.day - daysFromMonday, 0, 0, 0);
  }

  static Future<List<dynamic>> getActivityLogs({int limit = 50}) =>
      AdminData.logs(limit: limit, from: getStartOfCurrentWeekMonday()).then(_loose);

  static Future<List<int>?> downloadAuditLogPackageZip(String targetDate) async {
    try {
      return await AdminData.auditZip(targetDate);
    } catch (_) {
      return null;
    }
  }
  static Future<List<dynamic>> getMediaGallery() async {
    final rawList = await IncidentData.getMediaGallery();
    final weekStart = getStartOfCurrentWeekMonday();

    return _loose(rawList.where((raw) {
      final ts = DateTime.tryParse(raw['uploadedAt']?.toString() ?? '')?.toLocal();
      if (ts == null) return true;
      return ts.isAfter(weekStart) || ts.isAtSameMomentAs(weekStart);
    }));
  }

  static Future<List<dynamic>> getMediaFilters() => IncidentData.getMediaFilters().then(_loose);

  static Future<Map<String, dynamic>?> getIncidentDispatch(int reqId) async {
    try {
      return await IncidentData.getIncidentDispatch(reqId);
    } catch (_) {
      return null;
    }
  }

  // Notification API methods
  static Future<List<dynamic>> getNotifications(int userId) async {
    try {
      return _loose(await IncidentData.getNotifications(userId));
    } catch (_) {
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
    await IncidentData.addNotification(
      recipientId: recipientId,
      message: message,
      title: title,
      reqId: reqId,
      dispId: dispId,
    );
    return true;
  }

  static Future<bool> markNotificationAsRead(int notificationId) async {
    try {
      await IncidentData.markNotificationRead(notificationId);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> markAllNotificationsAsRead(int userId) async {
    try {
      await IncidentData.markAllNotificationsRead(userId);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<int> getUnreadNotificationCount(int userId) async {
    try {
      return await IncidentData.unreadNotificationCount(userId);
    } catch (_) {
      return 0;
    }
  }

  // Management screen methods
  static Future<List<dynamic>> getAccounts() async {
    try {
      return _loose(await AdminData.accounts());
    } catch (_) {
      return [];
    }
  }
  static Future<List<dynamic>> getVehiclesForManagement() async {
    try {
      return _loose(await VehicleData.getVehicles());
    } catch (_) {
      return [];
    }
  }

  static Future<List<dynamic>> getDepartments() async {
    try {
      return _loose(await VehicleData.getDepartments());
    } catch (_) {
      return [];
    }
  }

  static Future<bool> createAccount(Map<String, dynamic> accountData) async {
    try {
      await AdminData.createAccount(accountData);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> updateAccount(
    int accountId,
    Map<String, dynamic> accountData,
  ) async {
    try {
      await AdminData.updateAccount(accountId, accountData);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Disables the account (deleting another user's login needs a server).
  static Future<bool> deleteAccount(int accountId) async {
    try {
      await AdminData.disableAccount(accountId);
      return true;
    } catch (_) {
      return false;
    }
  }
  static Future<bool> createVehicle(Map<String, dynamic> vehicleData) async {
    try {
      await VehicleData.createVehicle(vehicleData);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> updateVehicle(
    int vehicleId,
    Map<String, dynamic> vehicleData,
  ) async {
    try {
      await VehicleData.updateVehicle(vehicleId, vehicleData);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> deleteVehicle(int vehicleId) async {
    try {
      await VehicleData.deleteVehicle(vehicleId);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> updateDepartment(
    Map<String, dynamic> departmentData,
  ) async {
    try {
      await VehicleData.updateDepartment(departmentData);
      return true;
    } catch (_) {
      return false;
    }
  }

  // Dispatch status management
  static Future<bool> updateDispatchStatus(int dispId, String status) async {
    try {
      await IncidentData.updateDispatchStatus(dispId, status);
      return true;
    } catch (_) {
      return false;
    }
  }

  // Push tokens are only useful with a server to send pushes; nothing to store on the free plan.
  static Future<bool> updateFcmToken(int userId, String fcmToken) async => true;

  // System logs
  static Future<List<dynamic>> getSystemLogs({
    int? userId,
    String? action,
    String? entityType,
    int limit = 100,
  }) async {
    try {
      return _loose(await AdminData.filteredLogs(userId: userId, action: action, entityType: entityType, limit: limit));
    } catch (_) {
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
    await IncidentData.log(action, entityType ?? 'SYSTEM', entityId, {'details': details});
    return true;
  }

  static Future<List<dynamic>> getSystemLogStats() async => [];

  // Enhanced system log methods
  static Future<List<dynamic>> getSystemLogsEnhanced({
    int? userId,
    String? action,
    String? entityType,
    int limit = 100,
    String? startDate,
    String? endDate,
  }) async {
    try {
      return _loose(await AdminData.filteredLogs(
          userId: userId, action: action, entityType: entityType, limit: limit, startDate: startDate, endDate: endDate));
    } catch (_) {
      return [];
    }
  }

  static Future<List<dynamic>> getSystemLogSummary() async => [];

  static Future<String> exportSystemLogs({
    String? startDate,
    String? endDate,
    String? entityType,
    String? action,
  }) async {
    final rows = await AdminData.filteredLogs(
        action: action, entityType: entityType, limit: 1 << 30, startDate: startDate, endDate: endDate);
    return AdminData.exportCsv(rows);
  }

  static Future<Map<String, dynamic>?> getUserSettings(int userId) async {
    try {
      return await AdminData.getSettings(userId);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> updateUserSettings(int userId, Map<String, dynamic> settings) async {
    try {
      await AdminData.updateSettings(userId, settings);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<({bool success, String message})> changeUserPassword({
    required int userId,
    required String currentPassword,
    required String newPassword,
  }) async {
    try {
      return await AdminData.changePassword(currentPassword, newPassword);
    } catch (e) {
      return (success: false, message: e is HttpException ? e.message : 'Could not change password.');
    }
  }

  static Future<Map<String, dynamic>?> getUserProfile(int userId) async {
    try {
      return await AdminData.getProfile(userId);
    } catch (_) {
      return null;
    }
  }}
