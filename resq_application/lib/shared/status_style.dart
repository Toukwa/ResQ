/// The one set of status words and colours every screen uses, for reports and
/// vehicles alike: Pending (amber), Accepted (teal), En Route (blue), Arrived
/// (purple), Completed and Available (green), Declined (red, also covers
/// Cancelled), Invalid (violet, prank reports) and Offline (grey).
library;

import 'package:flutter/material.dart';

import '../services/theme_service.dart';

/// A report's status as shown to staff and citizens.
String reportStatusLabel(dynamic raw) {
  final s = '${raw ?? ''}'.trim().toLowerCase();
  return switch (s) {
    'accepted' || 'ack' || 'acknowledged' => 'Accepted',
    'dispatched' || 'en route' || 'en_route' || 'active' || 'in_progress' || 'in progress' => 'En Route',
    'arrived' || 'on scene' => 'Arrived',
    'completed' || 'done' || 'resolved' => 'Completed',
    'declined' || 'denied' || 'cancelled' || 'canceled' => 'Declined',
    'invalid' => 'Invalid',
    _ => 'Pending',
  };
}

/// A vehicle's status as shown on every screen. An empty status counts as Available,
/// the status a vehicle is created with.
String vehicleStatusLabel(dynamic raw) {
  final s = '${raw ?? ''}'.trim().toLowerCase();
  return switch (s) {
    '' || 'available' || 'ready' || 'idle' || '1' => 'Available',
    'dispatched' || 'en route' || 'en_route' || 'busy' || 'in use' || 'in_progress' || 'in progress' || 'responding' => 'En Route',
    'arrived' || 'on scene' => 'Arrived',
    'offline' || 'maintenance' || 'inactive' => 'Offline',
    _ => 'Offline',
  };
}

/// Text / dot colour for any report or vehicle status (raw or already a label).
Color statusColor(String status) {
  final dark = ThemeService.instance.isDark;
  return switch (_key(status)) {
    'pending' => dark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
    'accepted' => dark ? const Color(0xFF2DD4BF) : const Color(0xFF0D9488),
    'en route' => dark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
    'arrived' => dark ? const Color(0xFFC084FC) : const Color(0xFF8B5CF6),
    'completed' || 'available' => dark ? const Color(0xFF34D399) : const Color(0xFF16A34A),
    'declined' => dark ? const Color(0xFFF87171) : const Color(0xFFDC2626),
    'invalid' => dark ? const Color(0xFFA78BFA) : const Color(0xFF7C3AED),
    _ => dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B), // offline
  };
}

/// Pale badge background for [status].
Color statusBgColor(String status) {
  final dark = ThemeService.instance.isDark;
  return switch (_key(status)) {
    'pending' => dark ? const Color(0xFF451A03) : const Color(0xFFFEF3C7),
    'accepted' => dark ? const Color(0xFF134E4A) : const Color(0xFFCCFBF1),
    'en route' => dark ? const Color(0xFF1E3A8A) : const Color(0xFFEFF6FF),
    'arrived' => dark ? const Color(0xFF2E1065) : const Color(0xFFF3E8FF),
    'completed' || 'available' => dark ? const Color(0xFF064E3B) : const Color(0xFFDCFCE7),
    'declined' => dark ? const Color(0xFF450A0A) : const Color(0xFFFEF2F2),
    'invalid' => dark ? const Color(0xFF2E1065) : const Color(0xFFF5F3FF),
    _ => dark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
  };
}

/// Badge border for [status].
Color statusBorderColor(String status) => statusColor(status).withValues(alpha: 0.35);

String _key(String status) {
  final s = status.trim().toLowerCase();
  if (s == 'available' || s == 'offline' || s == 'maintenance' || s == 'inactive') {
    return vehicleStatusLabel(s).toLowerCase();
  }
  return reportStatusLabel(s).toLowerCase();
}

/// Whether a report with this status is closed (no more work on it).
bool isClosedStatus(dynamic raw) => const {'Completed', 'Declined', 'Invalid'}.contains(reportStatusLabel(raw));

/// Whether a report with this status is open (Pending, Accepted, En Route or Arrived).
bool isOpenStatus(dynamic raw) => !isClosedStatus(raw);

/// Label and colours for a report status badge, in the shape the dashboard cards use.
Map<String, dynamic> statusBadgeConfig(dynamic raw) {
  final ts = ThemeService.instance;
  final label = reportStatusLabel(raw);
  return {
    'label': label,
    'textColor': statusColor(label),
    'bgColor': statusBgColor(label),
    'borderColor': statusBorderColor(label),
    'dotColor': statusColor(label),
    'cardBg': ts.cardBackground,
    'cardBorder': ts.borderColor,
  };
}

/// Queue filter chips on the dashboards: 'all', 'pending', 'enRoute' (En Route or
/// Arrived), 'declined', 'active' (Accepted, En Route or Arrived). [openOnly]: 'all'
/// means every open report instead of every report.
bool queueFilterMatches(String filter, dynamic raw, {bool openOnly = false}) {
  final s = reportStatusLabel(raw);
  return switch (filter) {
    'pending' => s == 'Pending',
    'enRoute' => s == 'En Route' || s == 'Arrived',
    'declined' => s == 'Declined',
    'active' => s == 'Accepted' || s == 'En Route' || s == 'Arrived',
    _ => !openOnly || isOpenStatus(raw),
  };
}
