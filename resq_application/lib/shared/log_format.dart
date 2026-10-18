/// Turning system log rows into the timeline entries both Activity Log screens
/// (Admin and Super Admin) show.
library;

import 'package:flutter/material.dart';
import 'log_details.dart';
import 'package:intl/intl.dart';

import '../services/theme_service.dart';

Map<String, dynamic>? parseLogEvent(Map<String, dynamic> log) {
  try {
    final String action = log['action']?.toString() ?? 'SYSTEM_EVENT';
    final String entityType = log['entity_type']?.toString() ?? 'system';
    final String status = log['status']?.toString() ?? 'SUCCESS';
    final String actorDisplay =
        log['actor_display']?.toString() ?? log['user_role']?.toString() ?? log['userName']?.toString() ?? 'System';

    String iconName = 'notifications_none';
    String iconBg = '#F1F5F9';
    String iconColor = '#64748B';
    String typeBg = '#E2E8F0';
    String typeColor = '#475569';

    if (status == 'FAILED' || action.startsWith('PRANK_WARNING')) {
      iconName = 'warning_amber_rounded';
      iconBg = '#FEF2F2';
      iconColor = '#EF4444';
      typeBg = '#FEE2E2';
      typeColor = '#991B1B';
    } else if (entityType == 'emergency_request') {
      iconName = 'warning_amber_rounded';
      iconBg = '#FFF7ED';
      iconColor = '#EA580C';
      typeBg = '#FFEDD5';
      typeColor = '#C2410C';
    } else if (entityType == 'dispatch_event') {
      iconName = 'local_shipping_outlined';
      iconBg = '#EFF6FF';
      iconColor = '#2563EB';
      typeBg = '#DBEAFE';
      typeColor = '#1E40AF';
    } else if (entityType == 'response_vehicle') {
      iconName = 'sync_rounded';
      iconBg = '#F0FDF4';
      iconColor = '#16A34A';
      typeBg = '#DCFCE7';
      typeColor = '#15803D';
    }

    DateTime parsedTime;
    try {
      final timestampStr =
          log['timestamp']?.toString() ?? log['created_at']?.toString() ?? log['createdAt']?.toString() ?? '';

      if (timestampStr.isNotEmpty) {
        parsedTime = DateTime.parse(timestampStr).toLocal();
      } else {
        parsedTime = DateTime.now();
      }
    } catch (e) {
      parsedTime = DateTime.now();
    }

    return {
      'id': log['log_id'],
      'title': actorDisplay,
      'type': action,
      'category': entityType,
      'description': LogDetails.describe(Map<String, dynamic>.from(log)),
      'raw': Map<String, dynamic>.from(log),
      'status': status,
      'requestId': log['entity_id']?.toString() ?? 'N/A',
      'time': DateFormat('hh:mm a').format(parsedTime),
      'date': DateFormat('yyyy-MM-dd').format(parsedTime),
      'timestamp': parsedTime.toIso8601String(),
      'source': "Real-time Audit Stream",
      'icon': iconName,
      'iconBg': iconBg,
      'iconColor': iconColor,
      'typeBg': typeBg,
      'typeColor': typeColor,
      'details': log['details']?.toString() ?? '',
      'tags': [
        {'text': entityType, 'bg': typeBg, 'color': typeColor},
        {
          'text': status,
          'bg': status == 'SUCCESS' ? '#DCFCE7' : '#FEE2E2',
          'color': status == 'SUCCESS' ? '#15803D' : '#991B1B',
        },
      ],
    };
  } catch (e) {
    debugPrint('Error parsing single log event: $e');
    return null;
  }
}

Color parseLogColor(String colorString) {
  try {
    final ts = ThemeService.instance;
    if (colorString.startsWith('#')) {
      final upper = colorString.toUpperCase();
      if (ts.isDark) {
        if (upper == '#E2E8F0') {
          return const Color(0xFF334155);
        }
        if (upper == '#475569') {
          return const Color(0xFFE2E8F0);
        }
        if (upper == '#F1F5F9' || upper == '#F8FAFC' || upper == '#FAFAFA' || upper == '#FFFFFF') {
          return const Color(0xFF1E293B);
        }
        if (upper == '#FEF2F2' || upper == '#FFF0F0' || upper == '#FFEAEA') {
          return const Color(0xFF450A0A);
        }
        if (upper == '#FEE2E2') {
          return const Color(0xFF5F1D24);
        }
        if (upper == '#991B1B') {
          return const Color(0xFFFCA5A5);
        }
        if (upper == '#FFF7ED' || upper == '#FFF3CD' || upper == '#FFEDD5') {
          return const Color(0xFF431407);
        }
        if (upper == '#C2410C') {
          return const Color(0xFFFDBA74);
        }
        if (upper == '#EFF6FF' || upper == '#EBF5FF' || upper == '#E0F2FE' || upper == '#DBEAFE') {
          return const Color(0xFF1E3A8A);
        }
        if (upper == '#1E40AF') {
          return const Color(0xFF93C5FD);
        }
        if (upper == '#F0FDF4' || upper == '#ECFDF5' || upper == '#DCFCE7' || upper == '#D1FAE5') {
          return const Color(0xFF064E3B);
        }
        if (upper == '#15803D') {
          return const Color(0xFF86EFAC);
        }
        if (upper == '#F3E8FF' || upper == '#F5F3FF') {
          return const Color(0xFF3B0764);
        }
        if (upper == '#0F172A' || upper == '#1E293B' || upper == '#000000') {
          return const Color(0xFFF8FAFC);
        }
        if (upper == '#334155' || upper == '#64748B') {
          return const Color(0xFFCBD5E1);
        }
        if (upper == '#16A34A' || upper == '#10B981') {
          return const Color(0xFF6EE7B7);
        }
        if (upper == '#2563EB' || upper == '#3B82F6') {
          return const Color(0xFF93C5FD);
        }
        if (upper == '#DC2626' || upper == '#EF4444') {
          return const Color(0xFFFCA5A5);
        }
        if (upper == '#EA580C' || upper == '#D97706') {
          return const Color(0xFFFDBA74);
        }
        if (upper == '#9333EA' || upper == '#8B5CF6') {
          return const Color(0xFFC084FC);
        }
      }
      return Color(int.parse(colorString.substring(1), radix: 16) + 0xFF000000);
    }
    return Colors.grey;
  } catch (e) {
    return Colors.grey;
  }
}
