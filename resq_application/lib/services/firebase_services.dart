import 'dart:io';
import 'package:flutter/foundation.dart';
import '../shared/iriga_address.dart';

import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'email_otp_service.dart';
import 'admin_data.dart';
import 'firebase_rest.dart';
import 'google_auth.dart';
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
    await _applyPendingEmail(uid, email);
    return _afterSignIn(uid);
  }

  /// A Super Admin changed this account's email: logging in with the new one finishes it;
  /// logging in with the old one sends the confirmation link to the new address.
  static Future<void> _applyPendingEmail(String uid, String typedEmail) async {
    try {
      final pending = await Rtdb.get('users/$uid/pendingEmail');
      if (pending is! String || pending.isEmpty) return;
      if (pending.toLowerCase() == typedEmail.trim().toLowerCase()) {
        await Rtdb.update('users/$uid', {'email': pending.toLowerCase(), 'pendingEmail': null});
      } else {
        await FirebaseAuthRest.sendEmailChangeLink(pending);
      }
    } catch (e) {
      debugPrint('Pending email change failed: $e');
    }
  }

  /// Google sign-in. A first-time Google user gets a Citizen profile.
  /// Returns null if the user closed the Google window.
  static Future<Map<String, dynamic>?> loginWithGoogle() async {
    final googleToken = await GoogleAuth.getIdToken();
    if (googleToken == null) return null;
    final account = await FirebaseAuthRest.signInWithGoogle(googleToken);

    if (await Rtdb.get('users/${account.uid}') == null) {
      final id = await Rtdb.nextId('counters/users');
      final user = {
        'id': id,
        'fullName': (account.name ?? account.email.split('@').first).trim(),
        'email': account.email.toLowerCase(),
        'contactNo': '',
        'role': 'Citizen',
        'createdAt': {'.sv': 'timestamp'},
      };
      await Rtdb.set('users/${account.uid}', user);
      await Rtdb.set('user_ids/$id', account.uid);
      await _logEvent(user, 'REGISTER', {'email': account.email, 'method': 'google'});
    }
    return _afterSignIn(account.uid);
  }

  /// Report Now on a phone that already has a guest account: back into it.
  /// Returns null when there is none (or it has since become a full account).
  static Future<Map<String, dynamic>?> resumeGuest() async {
    final uid = await FirebaseAuthRest.resumeGuest();
    if (uid == null) return null;
    try {
      final user = await _profile(uid);
      if (user['guest'] == true) return user;
    } catch (_) {}
    await FirebaseAuthRest.forgetGuest();
    await FirebaseAuthRest.signOut();
    return null;
  }

  /// Turns the signed-in guest into a full citizen account: same uid and reports,
  /// now with an email, password, birthdate and address.
  static Future<void> upgradeGuest({
    required String email,
    required String password,
    required String birthdate,
    required String barangay,
  }) async {
    await FirebaseAuthRest.linkEmailPassword(email, password);
    final uid = FirebaseAuthRest.uid!;
    await Rtdb.update('users/$uid', {
      'email': email.trim().toLowerCase(),
      'birthdate': birthdate,
      'barangay': barangay,
      'address': '$barangay, ${IrigaAddress.city}',
      'guest': null,
    });
    await FirebaseAuthRest.forgetGuest();
    await _logEvent(await _profile(uid), 'GUEST_REGISTERED', {'email': email});
  }

  /// Report Now: a guest Citizen profile with only a name and phone number,
  /// so someone can report an emergency without registering first.
  static Future<Map<String, dynamic>> quickReport({
    required String fullName,
    required String contactNo,
  }) async {
    final uid = await FirebaseAuthRest.signInAnonymously();
    final id = await Rtdb.nextId('counters/users');
    final user = {
      'id': id,
      'fullName': fullName.trim(),
      'email': '',
      'contactNo': contactNo.trim(),
      'role': 'Citizen',
      'guest': true,
      'createdAt': {'.sv': 'timestamp'},
    };
    await Rtdb.set('users/$uid', user);
    await Rtdb.set('user_ids/$id', uid);
    await _logEvent(user, 'REGISTER', {'method': 'report_now'});
    return {...user, 'uid': uid};
  }

  /// True for a Google account that has no password yet, so it can't use the
  /// email + password login.
  static Future<bool> needsPassword() async {
    try {
      final providers = await FirebaseAuthRest.providers();
      return providers.contains('google.com') && !providers.contains('password');
    } catch (_) {
      return false; // don't block sign-in over this check
    }
  }

  static Future<void> setPassword(String password) async {
    await FirebaseAuthRest.setPassword(password);
    await _logEvent(await _profile(FirebaseAuthRest.uid!), 'PASSWORD_ADDED', {'method': 'google_account'});
  }

  /// Fills in the birthdate and address for accounts made without the sign-up
  /// form (Google, or accounts created before these fields existed).
  static Future<void> saveProfileDetails({
    required String birthdate,
    required String barangay,
  }) async {
    final uid = FirebaseAuthRest.uid!;
    await Rtdb.update('users/$uid', {
      'birthdate': birthdate,
      'barangay': barangay,
      'address': '$barangay, ${IrigaAddress.city}',
    });
    await _logEvent(await _profile(uid), 'PROFILE_COMPLETED', {'barangay': barangay});
  }

  /// Shared by password and Google login: load the profile, then the email code check.
  static Future<Map<String, dynamic>?> _afterSignIn(String uid) async {
    final user = await _profile(uid);

    final settings = await Rtdb.get('user_settings/$uid');
    final mfaSetting = settings is Map ? settings['mfa_enabled'] : null;
    // Agency admins always get the code; only citizens and the EOC may turn it off
    final mfaEnabled = user['role'] == 'Admin' || (mfaSetting != false && mfaSetting != 0);

    // The email code is asked at sign-up, on a phone that hasn't passed it for this
    // account yet, and after a week without logging in
    if (mfaEnabled) {
      if (!await _isTrustedDevice(uid, user['id'])) return _sendLoginCode(user, reason: 'new_device');
      if (!await _loggedInRecently(uid)) return _sendLoginCode(user, reason: 'inactive');
    }

    await _markLoggedIn(uid);
    await _logEvent(user, 'LOGIN', {'email': user['email'], 'mfa': mfaEnabled ? 'skipped_recent_login' : false});
    return {'success': true, 'mfaRequired': false, 'user': user};
  }

  static Future<Map<String, dynamic>?> verifyMfa({
    required int userId,
    required String otpCode,
  }) async {
    final ok = await EmailOtpService.verify(otpCode);
    if (!ok) return {'success': false, 'error': 'Incorrect 6-digit verification code'};
    final user = await _profile(FirebaseAuthRest.uid!);
    await _markLoggedIn(FirebaseAuthRest.uid!);
    await _logEvent(user, 'LOGIN_MFA_VERIFIED', {'email': user['email'], 'mfa': true});
    return {'success': true, 'user': user};
  }

  static const _codeAfter = Duration(days: 7);

  /// Emails a code and tells the screen to ask for it.
  static Future<Map<String, dynamic>> _sendLoginCode(Map<String, dynamic> user, {String reason = 'signup'}) async {
    await EmailOtpService.sendCode(email: user['email'], userName: user['fullName'] ?? 'User', reason: reason);
    return {
      'success': true,
      'mfaRequired': true,
      'userId': user['id'],
      'targetEmail': user['email'],
      'maskedEmail': EmailOtpService.maskEmail(user['email']),
    };
  }

  /// True if this account logged in (and had passed the email code) within the last 7 days.
  static Future<bool> _loggedInRecently(String uid) async {
    try {
      final last = await Rtdb.get('user_settings/$uid/last_login');
      return last is int && DateTime.now().millisecondsSinceEpoch - last < _codeAfter.inMilliseconds;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _markLoggedIn(String uid) async {
    try {
      await Rtdb.update('user_settings/$uid', {'last_login': {'.sv': 'timestamp'}});
    } catch (_) {}
  }

  static String _hashToken(String token) => sha256.convert(utf8.encode(token)).toString();

  /// True if the email code was entered on this phone for this account.
  static Future<bool> _isTrustedDevice(String uid, dynamic userId) async {
    final id = int.tryParse('$userId');
    if (id == null) return false;
    final token = await SessionService.getDeviceToken(id);
    if (token == null) return false;
    try {
      return await Rtdb.get('trusted_devices/$uid/${_hashToken(token)}') != null;
    } catch (_) {
      return false;
    }
  }

  /// Remembers that this phone passed the email code (it stays trusted; only inactivity asks again).
  static Future<bool> trustDevice({
    required int userId,
    required String deviceToken,
    String deviceLabel = 'ResQ App',
  }) async {
    try {
      await Rtdb.set('trusted_devices/${FirebaseAuthRest.uid}/${_hashToken(deviceToken)}', {
        'label': deviceLabel,
        'trustedAt': {'.sv': 'timestamp'},
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
      // A week without logging in: back to the login screen for a fresh code
      if (device == null || !await _loggedInRecently(uid)) return null;
      await _markLoggedIn(uid);
      final user = await _profile(uid);
      await _logEvent(user, 'LOGIN_TRUSTED_DEVICE', {'email': user['email'], 'mfa': 'skipped_trusted_device'});
      return user;
    } catch (_) {
      return null;
    }
  }

  /// Signs out. This phone stays trusted for the account.
  static Future<void> signOut() => FirebaseAuthRest.signOut();

  static Future<void> sendPasswordReset(String email) => FirebaseAuthRest.sendPasswordReset(email);

  static Future<Map<String, dynamic>> register({
    required String fullName,
    required String contactNo,
    required String email,
    required String password,
    required String birthdate,
    required String barangay,
  }) async {
    final uid = await FirebaseAuthRest.signUp(email, password);
    final id = await Rtdb.nextId('counters/users');
    final user = {
      'id': id,
      'fullName': fullName.trim(),
      'email': email.trim().toLowerCase(),
      'contactNo': contactNo.trim(),
      'birthdate': birthdate,
      'barangay': barangay,
      'address': '$barangay, ${IrigaAddress.city}',
      'role': 'Citizen',
      'createdAt': {'.sv': 'timestamp'},
    };
    await Rtdb.set('users/$uid', user);
    await Rtdb.set('user_ids/$id', uid);
    await _logEvent(user, 'REGISTER', {'email': email});
    // Verify the new email straight away; entering the code logs them in
    return _sendLoginCode(user);
  }


  static Future<String> createIncident({
    required String citizenId,
    required String incidentType,
    required String description,
    required double latitude,
    required double longitude,
    File? image,
    List<File>? images,
    File? voiceNote,
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
      voiceNote: voiceNote,
    );
  }

  static Future<Map<String, dynamic>?> getEmergencyRequest(String reqId) async {
    try {
      return await IncidentData.getIncident(reqId);
    } catch (_) {
      return null;
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
    bool help = false,
  }) async {
    final id = await IncidentData.dispatchVehicle(
      reqId: reqId,
      vehicleId: vehicleId,
      adminId: adminId,
      department: department,
      help: help,
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

  static Future<List<int>?> downloadAuditLogPackageZip(String targetDate, {String department = 'ALL'}) async {
    try {
      return await AdminData.auditZip(targetDate, department: department);
    } catch (_) {
      return null;
    }
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

  /// What happened on the last createAccount call, for the screen to show.
  static String? lastAccountMessage;

  static Future<bool> createAccount(Map<String, dynamic> accountData) async {
    try {
      lastAccountMessage = await AdminData.createAccount(accountData);
      return true;
    } catch (e) {
      lastAccountMessage = e is HttpException ? e.message : 'Failed to create account.';
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

  /// Saves the signed-in user's own name, phone number and/or profile picture.
  static Future<void> updateMyProfile({String? fullName, String? contactNo, String? photoUrl}) async {
    final uid = FirebaseAuthRest.uid!;
    final changes = <String, dynamic>{
      if (fullName != null) 'fullName': fullName.trim(),
      if (contactNo != null) 'contactNo': contactNo.trim(),
      'photoUrl': ?photoUrl,
    };
    if (changes.isEmpty) return;
    await Rtdb.update('users/$uid', changes);
    await _logEvent(await _profile(uid), 'PROFILE_UPDATED', {'updatedFields': changes.keys.toList()});
  }

  static Future<Map<String, dynamic>?> getUserProfile(int userId) async {
    try {
      return await AdminData.getProfile(userId);
    } catch (_) {
      return null;
    }
  }}
