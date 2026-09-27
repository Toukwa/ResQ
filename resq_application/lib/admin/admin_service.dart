import '../services/firebase_services.dart';

class AdminService {
  static Future<List<dynamic>?> getAllVehicles() async {
    try {
      return await FirebaseService.getVehicles();
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> getDashboardMetrics() async {
    try {
      return await FirebaseService.getDashboardMetrics();
    } catch (_) {
      return null;
    }
  }

  static Future<List<dynamic>?> getActiveIncidentsList() async {
    try {
      return await FirebaseService.getActiveIncidents();
    } catch (_) {
      return null;
    }
  }

  static Future<List<dynamic>?> searchIncidents(String query) async {
    return await FirebaseService.searchIncidents(query);
  }

  static Future<String?> dispatchVehicle({
    required int reqId,
    required int vehicleId,
    required int adminId,
    String? department,
  }) async {
    try {
      return await FirebaseService.dispatchVehicle(
        reqId: reqId,
        vehicleId: vehicleId,
        adminId: adminId,
        department: department,
      );
    } catch (_) {
      return 'Failed to dispatch vehicle';
    }
  }

  static Future<bool> updateIncidentStatus({
    required int reqId,
    required String status,
    String? department,
  }) async {
    try {
      await FirebaseService.updateIncidentStatus(
        reqId: reqId,
        status: status,
        department: department,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<List<dynamic>?> getActivityLogs({int limit = 50}) async {
    try {
      return await FirebaseService.getActivityLogs(limit: limit);
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> getIncidentDispatch(int reqId) async {
    try {
      return await FirebaseService.getIncidentDispatch(reqId);
    } catch (_) {
      return null;
    }
  }

  // Notification methods
  static Future<List<dynamic>> getNotifications(int userId) async {
    try {
      return await FirebaseService.getNotifications(userId);
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
    try {
      return await FirebaseService.addNotification(
        recipientId: recipientId,
        message: message,
        title: title,
        reqId: reqId,
        dispId: dispId,
      );
    } catch (_) {
      return false;
    }
  }

  static Future<bool> markNotificationAsRead(int notificationId) async {
    try {
      return await FirebaseService.markNotificationAsRead(notificationId);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> markAllNotificationsAsRead(int userId) async {
    try {
      return await FirebaseService.markAllNotificationsAsRead(userId);
    } catch (_) {
      return false;
    }
  }

  static Future<int> getUnreadNotificationCount(int userId) async {
    try {
      return await FirebaseService.getUnreadNotificationCount(userId);
    } catch (_) {
      return 0;
    }
  }

  // Management screen methods
  static Future<List<dynamic>> getAccounts() async {
    try {
      return await FirebaseService.getAccounts();
    } catch (_) {
      return [];
    }
  }

  static Future<List<dynamic>> getVehicles() async {
    try {
      return await FirebaseService.getVehiclesForManagement();
    } catch (_) {
      return [];
    }
  }

  static Future<List<dynamic>> getDepartments() async {
    try {
      return await FirebaseService.getDepartments();
    } catch (_) {
      return [];
    }
  }

  static Future<bool> createAccount(Map<String, dynamic> accountData) async {
    try {
      return await FirebaseService.createAccount(accountData);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> updateAccount(
    int accountId,
    Map<String, dynamic> accountData,
  ) async {
    try {
      return await FirebaseService.updateAccount(accountId, accountData);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> deleteAccount(int accountId) async {
    try {
      return await FirebaseService.deleteAccount(accountId);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> createVehicle(Map<String, dynamic> vehicleData) async {
    try {
      return await FirebaseService.createVehicle(vehicleData);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> updateVehicle(
    int vehicleId,
    Map<String, dynamic> vehicleData,
  ) async {
    try {
      return await FirebaseService.updateVehicle(vehicleId, vehicleData);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> deleteVehicle(int vehicleId) async {
    try {
      return await FirebaseService.deleteVehicle(vehicleId);
    } catch (_) {
      return false;
    }
  }


  static Future<bool> updateDepartment(
    Map<String, dynamic> departmentData,
  ) async {
    try {
      return await FirebaseService.updateDepartment(departmentData);
    } catch (_) {
      return false;
    }
  }

  // Dispatch status management
  static Future<bool> updateDispatchStatus(int dispId, String status) async {
    try {
      return await FirebaseService.updateDispatchStatus(dispId, status);
    } catch (_) {
      return false;
    }
  }

  // FCM token management
  static Future<bool> updateFcmToken(int userId, String fcmToken) async {
    try {
      return await FirebaseService.updateFcmToken(userId, fcmToken);
    } catch (_) {
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
    try {
      return await FirebaseService.getSystemLogs(
        userId: userId,
        action: action,
        entityType: entityType,
        limit: limit,
      );
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
    try {
      return await FirebaseService.addSystemLog(
        userId: userId,
        action: action,
        entityType: entityType,
        entityId: entityId,
        details: details,
        ipAddress: ipAddress,
      );
    } catch (_) {
      return false;
    }
  }

  static Future<List<dynamic>> getSystemLogStats() async {
    try {
      return await FirebaseService.getSystemLogStats();
    } catch (_) {
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
    try {
      return await FirebaseService.getSystemLogsEnhanced(
        userId: userId,
        action: action,
        entityType: entityType,
        limit: limit,
        startDate: startDate,
        endDate: endDate,
      );
    } catch (_) {
      return [];
    }
  }

  static Future<List<dynamic>> getSystemLogSummary() async {
    try {
      return await FirebaseService.getSystemLogSummary();
    } catch (_) {
      return [];
    }
  }

  static Future<String> exportSystemLogs({
    String? startDate,
    String? endDate,
    String? entityType,
    String? action,
  }) async {
    return await FirebaseService.exportSystemLogs(
      startDate: startDate,
      endDate: endDate,
      entityType: entityType,
      action: action,
    );
  }

  // User Settings & Profile
  static Future<Map<String, dynamic>?> getUserSettings(int userId) async {
    return await FirebaseService.getUserSettings(userId);
  }

  static Future<bool> updateUserSettings(
    int userId,
    Map<String, dynamic> settings,
  ) async {
    return await FirebaseService.updateUserSettings(userId, settings);
  }

  static Future<Map<String, dynamic>> changePassword({
    required int userId,
    required String currentPassword,
    required String newPassword,
  }) async {
    final res = await FirebaseService.changeUserPassword(
      userId: userId,
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
    return {'success': res.success, 'message': res.message};
  }

  static Future<Map<String, dynamic>?> getUserProfile(int userId) async {
    return await FirebaseService.getUserProfile(userId);
  }
}