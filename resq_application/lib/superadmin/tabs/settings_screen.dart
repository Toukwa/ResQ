import 'dart:async';
import 'package:flutter/material.dart';
import 'package:rxdart/rxdart.dart';
import '../../admin/admin_service.dart';
import '../../services/theme_service.dart';
import '../../shared/sound_preview.dart';
import '../../services/sound_service.dart';
import '../../shared/tab_activity.dart';
import '../../shared/display_settings.dart';
enum SettingsCategory {
  appearance,
  alerts,
  map,
  security,
}
class SettingsScreen extends StatefulWidget {
  final String searchFilter;
  final int userId;
  const SettingsScreen({
    super.key,
    required this.searchFilter,
    this.userId = 13,
  });
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}
class _SettingsScreenState extends State<SettingsScreen> {
  SettingsCategory _selectedCategory = SettingsCategory.appearance;
  // Loading and Saving states
  bool _isLoading = true;
  bool _isSaving = false;
  String? _saveStatusMessage;
  // Authenticated user profile
  String _userName = 'Super Admin';
  String _userRole = 'Super Admin';
  String _userInitials = 'SA';
  // Appearance state (backed by user_settings table)
  String _themeMode = 'Light';
  bool _reducedMotion = false;
  // Alerts & Notifications state (backed by user_settings table)
  bool _criticalEmergencyAlerts = true;
  bool _unitStatusUpdates = true;
  bool _incidentUpdates = true;
  bool _soundAlerts = true;
  bool _tabActivityDots = true;
  // Map Settings state (backed by user_settings table)
  bool _autoCenterOnIncident = true;
  bool _showUnitLabels = true;
  // Account Security state (backed by user_settings table)
  bool _mfa = true;
  String _sessionTimeout = '15 min';
  bool _autoLogout = true;
  // RxDart Subjects for responsive state and debounced updates
  final BehaviorSubject<String> _searchSubject = BehaviorSubject<String>();
  final PublishSubject<String> _statusMessageSubject = PublishSubject<String>();
  StreamSubscription? _searchSubscription;
  StreamSubscription? _statusSubscription;
  @override
  void initState() {
    super.initState();
    _setupRxDart();
    _loadAllData();
  }
  void _setupRxDart() {
    _searchSubscription = _searchSubject
        .debounceTime(const Duration(milliseconds: 300))
        .distinct()
        .listen((_) {
      if (mounted) setState(() {});
    });
    _statusSubscription = _statusMessageSubject
        .debounceTime(const Duration(seconds: 4))
        .listen((_) {
      if (mounted) {
        setState(() => _saveStatusMessage = null);
      }
    });
  }
  @override
  void dispose() {
    _searchSubscription?.cancel();
    _statusSubscription?.cancel();
    _searchSubject.close();
    _statusMessageSubject.close();
    super.dispose();
  }
  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId) {
      _loadAllData();
    }
  }
  Future<void> _loadAllData() async {
    setState(() => _isLoading = true);
    await Future.wait([
      _loadUserSettings(),
      _loadUserProfile(),
    ]);
    if (mounted) {
      setState(() => _isLoading = false);
    }
  }
  Future<void> _loadUserSettings() async {
    try {
      final settings = await AdminService.getUserSettings(widget.userId);
      if (settings != null && mounted) {
        setState(() {
          _themeMode = (settings['theme_mode'] as String?) ?? 'Light';
          ThemeService.instance.setThemeMode(_themeMode);
          _reducedMotion = _toBool(settings['reduced_motion']);
          _criticalEmergencyAlerts = _toBool(settings['critical_emergency_alerts'], defaultValue: true);
          _unitStatusUpdates = _toBool(settings['unit_status_updates'], defaultValue: true);
          _incidentUpdates = _toBool(settings['incident_updates'], defaultValue: true);
          _soundAlerts = _toBool(settings['sound_alerts'], defaultValue: true);
          _tabActivityDots = _toBool(settings['tab_activity_dots'], defaultValue: true);
          _autoCenterOnIncident = _toBool(settings['auto_center_on_incident'], defaultValue: true);
          _showUnitLabels = _toBool(settings['show_unit_labels'], defaultValue: true);
          _mfa = _toBool(settings['mfa_enabled'], defaultValue: true);
          _sessionTimeout = (settings['session_timeout'] as String?) ?? '15 min';
          _autoLogout = _toBool(settings['auto_logout'], defaultValue: true);
        });
      }
    } catch (e) {
      debugPrint('Error loading user settings: $e');
    }
  }
  bool _toBool(dynamic val, {bool defaultValue = false}) {
    if (val == null) return defaultValue;
    if (val is bool) return val;
    if (val is int) return val == 1;
    if (val is String) return val == '1' || val.toLowerCase() == 'true';
    return defaultValue;
  }
  Future<void> _loadUserProfile() async {
    try {
      final profile = await AdminService.getUserProfile(widget.userId);
      if (profile != null && mounted) {
        final name = (profile['name'] as String?) ?? 'Super Admin';
        final role = (profile['role'] as String?) ?? 'Super Admin';
        final parts = name.trim().split(RegExp(r'\s+'));
        String initials = 'SA';
        if (parts.length >= 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
          initials = '${parts[0][0]}${parts[1][0]}'.toUpperCase();
        } else if (parts.isNotEmpty && parts[0].isNotEmpty) {
          initials = parts[0].substring(0, parts[0].length >= 2 ? 2 : 1).toUpperCase();
        }
        setState(() {
          _userName = name;
          _userRole = role;
          _userInitials = initials;
        });
      }
    } catch (e) {
      debugPrint('Error loading user profile: $e');
    }
  }
  Future<void> _saveSetting(Map<String, dynamic> partial) async {
    setState(() {
      _isSaving = true;
      _saveStatusMessage = 'Saving...';
    });
    try {
      final success = await AdminService.updateUserSettings(widget.userId, partial);
      if (mounted) {
        setState(() {
          _isSaving = false;
          _saveStatusMessage = success ? 'Saved' : 'Failed to save';
        });
        if (success) {
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted && _saveStatusMessage == 'Saved') {
              setState(() => _saveStatusMessage = null);
            }
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _saveStatusMessage = 'Error saving';
        });
      }
    }
  }
  bool _matchesSearch(String title, String subtitle) {
    if (widget.searchFilter.trim().isEmpty) return true;
    final query = widget.searchFilter.trim().toLowerCase();
    return title.toLowerCase().contains(query) || subtitle.toLowerCase().contains(query);
  }
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeService.instance,
      builder: (context, _) {
        final pageBg = ThemeService.instance.pageBackground;
        return Scaffold(
          backgroundColor: pageBg,
          body: SafeArea(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              color: pageBg,
          child: Column(
            children: [
              // Search Filter Indicator
              if (widget.searchFilter.isNotEmpty)
                Container(
                  width: double.infinity,
                  color: Colors.orange.shade50,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.search, size: 16, color: Colors.orange),
                      const SizedBox(width: 8),
                      Text(
                        "Filtering settings for: '${widget.searchFilter}'",
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.orange,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              // Content View (Sidebar Menu + Main Detail Panel)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Secondary Settings Menu Panel
                      SizedBox(
                        width: 240,
                        child: _buildSettingsMenuPanel(),
                      ),
                      const SizedBox(width: 20),
                      // Main Category Detail Panel
                      Expanded(
                        child: _isLoading
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const CircularProgressIndicator(strokeWidth: 3),
                                    const SizedBox(height: 16),
                                    Text(
                                      'Loading settings...',
                                      style: TextStyle(color: ThemeService.instance.textSecondary, fontSize: 14),
                                    ),
                                  ],
                                ),
                              )
                            : _buildMainDetailPanel(),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
      },
    );
  }
  // ---------------------------------------------------------------------------
  // SETTINGS MENU PANEL (Left Column inside Page)
  // ---------------------------------------------------------------------------
  Widget _buildSettingsMenuPanel() {
    final cardBg = ThemeService.instance.cardBackground;
    final border = ThemeService.instance.borderColor;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(
            color: ThemeService.instance.shadowColor,
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 12, top: 8, bottom: 12),
            child: Text(
              'SETTINGS MENU',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Color(0xFF9CA3AF),
                letterSpacing: 0.5,
              ),
            ),
          ),
          _buildMenuItem(
            category: SettingsCategory.appearance,
            title: 'Appearance',
            icon: Icons.wb_sunny_outlined,
            activeColor: const Color(0xFFFF4D00),
          ),
          _buildMenuItem(
            category: SettingsCategory.alerts,
            title: 'Alerts & Notifications',
            icon: Icons.notifications_none_rounded,
            activeColor: const Color(0xFFEF4444),
          ),
          _buildMenuItem(
            category: SettingsCategory.map,
            title: 'Map Settings',
            icon: Icons.map_outlined,
            activeColor: const Color(0xFF10B981),
          ),
          _buildMenuItem(
            category: SettingsCategory.security,
            title: 'Account Security',
            icon: Icons.shield_outlined,
            activeColor: const Color(0xFF3B82F6),
          ),
          const Spacer(),
          // Authenticated User Avatar Footnote Card
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: ThemeService.instance.isDark ? ThemeService.instance.inputBackground : const Color(0xFFF9FAFB),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: ThemeService.instance.borderColor),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: const Color(0xFF0066FF),
                  child: Text(
                    _userInitials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _userName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: ThemeService.instance.textPrimary,
                        ),
                      ),
                      Text(
                        _userRole,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: ThemeService.instance.textSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  Widget _buildMenuItem({
    required SettingsCategory category,
    required String title,
    required IconData icon,
    required Color activeColor,
  }) {
    final isSelected = _selectedCategory == category;
    final ts = ThemeService.instance;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            setState(() {
              _selectedCategory = category;
            });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isSelected ? activeColor.withValues(alpha: 0.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: isSelected ? activeColor : ts.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                      color: isSelected ? activeColor : ts.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  // ---------------------------------------------------------------------------
  // MAIN DETAIL PANEL
  // ---------------------------------------------------------------------------
  Widget _buildMainDetailPanel() {
    final contentWidgets = _buildCategoryContent();
    final cardBg = ThemeService.instance.cardBackground;
    final border = ThemeService.instance.borderColor;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      width: double.infinity,
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(
            color: ThemeService.instance.shadowColor,
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with Save / Status Indicator
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildCategoryHeader(),
              Row(
                children: [
                  if (_isSaving)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Saving...',
                            style: TextStyle(fontSize: 12, color: Color(0xFF4B5563)),
                          ),
                        ],
                      ),
                    )
                  else if (_saveStatusMessage != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: _saveStatusMessage == 'Saved'
                            ? const Color(0xFFDEF7EC)
                            : const Color(0xFFFDE8E8),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _saveStatusMessage == 'Saved' ? Icons.check_circle : Icons.error_outline,
                            size: 14,
                            color: _saveStatusMessage == 'Saved'
                                ? const Color(0xFF0E9F6E)
                                : const Color(0xFFE02424),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _saveStatusMessage!,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _saveStatusMessage == 'Saved'
                                  ? const Color(0xFF0E9F6E)
                                  : const Color(0xFFE02424),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, size: 20, color: Color(0xFF6B7280)),
                    tooltip: 'Refresh Settings',
                    onPressed: _isLoading ? null : _loadAllData,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(color: Color(0xFFF3F4F6), height: 1),
          Expanded(
            child: SingleChildScrollView(
              child: contentWidgets.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                        child: Column(
                          children: [
                            const Icon(Icons.search_off_rounded, size: 40, color: Color(0xFF9CA3AF)),
                            const SizedBox(height: 12),
                            Text(
                              "No settings match '${widget.searchFilter}' in this category",
                              style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
                            ),
                          ],
                        ),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: contentWidgets,
                    ),
            ),
          ),
        ],
      ),
    );
  }
  Widget _buildCategoryHeader() {
    switch (_selectedCategory) {
      case SettingsCategory.appearance:
        return _buildHeaderItem('Appearance', 'Configure appearance preferences', Icons.wb_sunny_outlined, const Color(0xFFFF4D00));
      case SettingsCategory.alerts:
        return _buildHeaderItem('Alerts & Notifications', 'Configure alerts & notifications preferences', Icons.notifications_none_rounded, const Color(0xFFEF4444));
      case SettingsCategory.map:
        return _buildHeaderItem('Map Settings', 'Configure map display and navigation preferences', Icons.map_outlined, const Color(0xFF10B981));
      case SettingsCategory.security:
        return _buildHeaderItem('Account Security', 'Manage security, session timeout, and password', Icons.shield_outlined, const Color(0xFF3B82F6));
    }
  }
  Widget _buildHeaderItem(String title, String subtitle, IconData icon, Color color) {
    final textPrimary = ThemeService.instance.textPrimary;
    final textSecondary = ThemeService.instance.textSecondary;
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textPrimary),
              child: Text(title),
            ),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: TextStyle(fontSize: 12, color: textSecondary),
              child: Text(subtitle),
            ),
          ],
        ),
      ],
    );
  }
  // ---------------------------------------------------------------------------
  // CONTENT SWITCHER BY CATEGORY
  // ---------------------------------------------------------------------------
  List<Widget> _buildCategoryContent() {
    switch (_selectedCategory) {
      case SettingsCategory.appearance:
        return _buildAppearanceContent();
      case SettingsCategory.alerts:
        return _buildAlertsContent();
      case SettingsCategory.map:
        return _buildMapContent();
      case SettingsCategory.security:
        return _buildSecurityContent();
    }
  }
  // --- APPEARANCE ---
  List<Widget> _buildAppearanceContent() {
    final list = <Widget>[];
    if (_matchesSearch('Interface Theme', 'Choose your preferred display theme')) {
      list.add(
        _buildRowLayout(
          icon: Icons.desktop_windows_outlined,
          title: 'Interface Theme',
          subtitle: 'Choose your preferred display theme',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildThemeOption('Light', Icons.wb_sunny_outlined, _themeMode == 'Light', const Color(0xFFFF4D00)),
              const SizedBox(width: 8),
              _buildThemeOption('Dark', Icons.nightlight_round, _themeMode == 'Dark', const Color(0xFFFF4D00)),
            ],
          ),
        ),
      );
    }
    if (_matchesSearch('Reduced Motion', 'Minimize animations and transitions')) {
      if (list.isNotEmpty) list.add(const Divider(color: Color(0xFFF3F4F6), height: 1));
      list.add(
        _buildRowLayout(
          icon: Icons.autorenew_rounded,
          title: 'Reduced Motion',
          subtitle: 'Minimize animations and transitions',
          trailing: Switch(
            value: _reducedMotion,
            onChanged: (v) {
              setState(() => _reducedMotion = v);
              DisplaySettings.reducedMotion.value = v;
              _saveSetting({'reduced_motion': v ? 1 : 0});
            },
            activeThumbColor: const Color(0xFFFF4D00),
          ),
        ),
      );
    }
    return list;
  }
  Widget _buildThemeOption(String label, IconData icon, bool isSelected, Color activeColor) {
    final ts = ThemeService.instance;
    return InkWell(
      onTap: () {
        setState(() => _themeMode = label);
        ThemeService.instance.setThemeMode(label);
        _saveSetting({'theme_mode': label});
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? (ts.isDark ? const Color(0xFF431407) : Colors.white)
              : (ts.isDark ? ts.inputBackground : const Color(0xFFF9FAFB)),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? activeColor.withValues(alpha: 0.8) : ts.borderColor,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: isSelected ? activeColor : ts.textSecondary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? activeColor : ts.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
  // --- ALERTS & NOTIFICATIONS ---
  List<Widget> _buildAlertsContent() {
    const activeColor = Color(0xFFEF4444);
    const accentOrange = Color(0xFFFF6B00);
    const accentPurple = Color(0xFF8B5CF6);
    final items = <Map<String, dynamic>>[
      {
        'icon': Icons.notifications_none_rounded,
        'title': 'Critical Emergency Alerts',
        'subtitle': 'Alarm and tab dot when a new report comes in',
        'value': _criticalEmergencyAlerts,
        'color': activeColor,
        'key': 'critical_emergency_alerts',
        'onChanged': (bool v) {
          setState(() => _criticalEmergencyAlerts = v);
          AlertCategory.critical.enabled = v;
          _saveSetting({'critical_emergency_alerts': v ? 1 : 0});
        },
      },
      {
        'icon': Icons.autorenew_rounded,
        'title': 'Unit Status Updates',
        'subtitle': 'Sound and tab dot when units are dispatched',
        'value': _unitStatusUpdates,
        'color': accentOrange,
        'key': 'unit_status_updates',
        'onChanged': (bool v) {
          setState(() => _unitStatusUpdates = v);
          AlertCategory.unitStatus.enabled = v;
          _saveSetting({'unit_status_updates': v ? 1 : 0});
        },
      },
      {
        'icon': Icons.notifications_none_rounded,
        'title': 'Incident Updates',
        'subtitle': 'Sound and tab dot when an incident is accepted, completed or declined',
        'value': _incidentUpdates,
        'color': accentOrange,
        'key': 'incident_updates',
        'onChanged': (bool v) {
          setState(() => _incidentUpdates = v);
          AlertCategory.incident.enabled = v;
          _saveSetting({'incident_updates': v ? 1 : 0});
        },
      },
      {
        'icon': Icons.circle_notifications_outlined,
        'title': 'Tab Activity Dots',
        'subtitle': 'Show a dot on sidebar tabs where something new happened',
        'value': _tabActivityDots,
        'color': accentPurple,
        'key': 'tab_activity_dots',
        'onChanged': (bool v) {
          setState(() => _tabActivityDots = v);
          TabActivity.enabled.value = v;
          _saveSetting({'tab_activity_dots': v ? 1 : 0});
        },
      },
      {
        'icon': Icons.volume_up_outlined,
        'title': 'Sound Alerts',
        'subtitle': 'Play a distinct sound for new reports, dispatches and status changes',
        'value': _soundAlerts,
        'color': accentPurple,
        'key': 'sound_alerts',
        'onChanged': (bool v) {
          setState(() => _soundAlerts = v);
          SoundService.enabled = v;
          _saveSetting({'sound_alerts': v ? 1 : 0});
        },
      },
    ];
    final list = <Widget>[];
    for (final item in items) {
      if (_matchesSearch(item['title'] as String, item['subtitle'] as String)) {
        if (list.isNotEmpty) list.add(const Divider(color: Color(0xFFF3F4F6), height: 1));
        list.add(
          _buildSwitchRow(
            item['icon'] as IconData,
            item['title'] as String,
            item['subtitle'] as String,
            item['value'] as bool,
            item['onChanged'] as ValueChanged<bool>,
            item['color'] as Color,
          ),
        );
      }
    }
    if (_soundAlerts && _matchesSearch('Alert sounds preview', 'sound')) list.add(const SoundPreviewPanel());
    return list;
  }
  // --- MAP SETTINGS ---
  List<Widget> _buildMapContent() {
    const activeColor = Color(0xFF10B981);
    final list = <Widget>[];
    final switches = [
      {
        'icon': Icons.autorenew_rounded,
        'title': 'Auto-Center on Incident',
        'subtitle': 'Automatically pan map to new incidents',
        'value': _autoCenterOnIncident,
        'onChanged': (bool v) {
          setState(() => _autoCenterOnIncident = v);
          DisplaySettings.autoCenterOnIncident.value = v;
          _saveSetting({'auto_center_on_incident': v ? 1 : 0});
        },
      },
      {
        'icon': Icons.map_outlined,
        'title': 'Show Unit Labels',
        'subtitle': 'Display unit IDs on map markers',
        'value': _showUnitLabels,
        'onChanged': (bool v) {
          setState(() => _showUnitLabels = v);
          DisplaySettings.showUnitLabels.value = v;
          _saveSetting({'show_unit_labels': v ? 1 : 0});
        },
      },
    ];
    for (final item in switches) {
      if (_matchesSearch(item['title'] as String, item['subtitle'] as String)) {
        if (list.isNotEmpty) list.add(const Divider(color: Color(0xFFF3F4F6), height: 1));
        list.add(
          _buildSwitchRow(
            item['icon'] as IconData,
            item['title'] as String,
            item['subtitle'] as String,
            item['value'] as bool,
            item['onChanged'] as ValueChanged<bool>,
            activeColor,
          ),
        );
      }
    }
    return list;
  }
  // --- ACCOUNT SECURITY ---
  List<Widget> _buildSecurityContent() {
    const activeColor = Color(0xFF0066FF);
    final list = <Widget>[];
    if (_matchesSearch('Multi-Factor Authentication', 'Require MFA for all logins')) {
      list.add(
        _buildSwitchRow(
          Icons.key_outlined,
          'Multi-Factor Authentication',
          'Require MFA for all logins',
          _mfa,
          (v) {
            setState(() => _mfa = v);
            _saveSetting({'mfa_enabled': v ? 1 : 0});
          },
          activeColor,
        ),
      );
    }
    if (_matchesSearch('Session Timeout', 'Auto-lock after inactivity')) {
      if (list.isNotEmpty) list.add(const Divider(color: Color(0xFFF3F4F6), height: 1));
      list.add(
        _buildRowLayout(
          icon: Icons.lock_outline_rounded,
          title: 'Session Timeout',
          subtitle: 'Auto-lock after inactivity',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _sessionTimeout,
                    isDense: true,
                    items: ['30 sec', '1 min', '5 min', '15 min', '30 min', '1 hour']
                        .map((val) => DropdownMenuItem(
                              value: val,
                              child: Text(val, style: const TextStyle(fontSize: 12)),
                            ))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) {
                        setState(() => _sessionTimeout = v);
                        _saveSetting({'session_timeout': v});
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Switch(
                value: _autoLogout,
                onChanged: (v) {
                  setState(() => _autoLogout = v);
                  _saveSetting({'auto_logout': v ? 1 : 0});
                },
                activeThumbColor: activeColor,
              ),
            ],
          ),
        ),
      );
    }
    if (_matchesSearch('Auto Logout on Inactivity', 'Force logout when session expires')) {
      if (list.isNotEmpty) list.add(const Divider(color: Color(0xFFF3F4F6), height: 1));
      list.add(
        _buildSwitchRow(
          Icons.shield_outlined,
          'Auto Logout on Inactivity',
          'Force logout when session expires',
          _autoLogout,
          (v) {
            setState(() => _autoLogout = v);
            _saveSetting({'auto_logout': v ? 1 : 0});
          },
          activeColor,
        ),
      );
    }
    if (_matchesSearch('Change Password', 'Update account authentication password')) {
      list.add(const SizedBox(height: 16));
      list.add(
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _showChangePasswordDialog,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: ThemeService.instance.isDark ? const Color(0xFF172554) : const Color(0xFFF0F6FF),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: ThemeService.instance.isDark ? const Color(0xFF1E3A8A) : const Color(0xFFE0EDFF)),
            ),
            child: Row(
              children: [
                Icon(Icons.lock_outline_rounded, color: _passwordAccent, size: 18),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Change Password',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: _passwordAccent,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Update your login credentials securely',
                      style: TextStyle(fontSize: 11, color: ThemeService.instance.textSecondary),
                    ),
                  ],
                ),
                const Spacer(),
                Icon(Icons.chevron_right_rounded, color: _passwordAccent, size: 20),
              ],
            ),
          ),
        ),
      );
    }
    return list;
  }
  // ---------------------------------------------------------------------------
  // CHANGE PASSWORD DIALOG MODAL
  // ---------------------------------------------------------------------------
  /// Brighter blue on dark backgrounds so the Change Password card stays readable.
  Color get _passwordAccent => ThemeService.instance.isDark ? const Color(0xFF60A5FA) : const Color(0xFF0066FF);

  void _showChangePasswordDialog() {
    final currentPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    bool obscureCurrent = true;
    bool obscureNew = true;
    bool obscureConfirm = true;
    bool isSubmitting = false;
    String? errorMessage;
    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.lock_reset_rounded, color: Color(0xFF0066FF)),
              SizedBox(width: 10),
              Text(
                'Change Password',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Ensure your account is using a secure password with at least 6 characters.',
                    style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
                  ),
                  const SizedBox(height: 16),
                  if (errorMessage != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFDE8E8),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFF8B4B4)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline, color: Color(0xFF9B1C1C), size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              errorMessage!,
                              style: const TextStyle(color: Color(0xFF9B1C1C), fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  // Current Password
                  const Text(
                    'Current Password',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF374151)),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: currentPasswordController,
                    obscureText: obscureCurrent,
                    decoration: InputDecoration(
                      hintText: 'Enter your current password',
                      hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscureCurrent ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                          size: 18,
                        ),
                        onPressed: () => setDialogState(() => obscureCurrent = !obscureCurrent),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // New Password
                  const Text(
                    'New Password',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF374151)),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: newPasswordController,
                    obscureText: obscureNew,
                    decoration: InputDecoration(
                      hintText: 'Enter new password (min. 6 chars)',
                      hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscureNew ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                          size: 18,
                        ),
                        onPressed: () => setDialogState(() => obscureNew = !obscureNew),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Confirm New Password
                  const Text(
                    'Confirm New Password',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF374151)),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: confirmPasswordController,
                    obscureText: obscureConfirm,
                    decoration: InputDecoration(
                      hintText: 'Confirm your new password',
                      hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscureConfirm ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                          size: 18,
                        ),
                        onPressed: () => setDialogState(() => obscureConfirm = !obscureConfirm),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: isSubmitting ? null : () => Navigator.pop(dialogCtx),
              child: const Text('Cancel', style: TextStyle(color: Color(0xFF6B7280))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0066FF),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              ),
              onPressed: isSubmitting
                  ? null
                  : () async {
                      final currentPass = currentPasswordController.text.trim();
                      final newPass = newPasswordController.text.trim();
                      final confirmPass = confirmPasswordController.text.trim();
                      if (currentPass.isEmpty) {
                        setDialogState(() => errorMessage = 'Please enter your current password.');
                        return;
                      }
                      if (newPass.length < 6) {
                        setDialogState(() => errorMessage = 'New password must be at least 6 characters.');
                        return;
                      }
                      if (newPass != confirmPass) {
                        setDialogState(() => errorMessage = 'New passwords do not match.');
                        return;
                      }
                      if (currentPass == newPass) {
                        setDialogState(() => errorMessage = 'New password cannot be identical to current password.');
                        return;
                      }
                      setDialogState(() {
                        isSubmitting = true;
                        errorMessage = null;
                      });
                      final messenger = ScaffoldMessenger.of(context);
                      final navigator = Navigator.of(dialogCtx);
                      final res = await AdminService.changePassword(
                        userId: widget.userId,
                        currentPassword: currentPass,
                        newPassword: newPass,
                      );
                      if (res['success'] == true) {
                        navigator.pop();
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text('Password updated successfully!'),
                            backgroundColor: Color(0xFF0E9F6E),
                          ),
                        );
                      } else {
                        setDialogState(() {
                          isSubmitting = false;
                          errorMessage = (res['message'] as String?) ?? 'Failed to update password.';
                        });
                      }
                    },
              child: isSubmitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Update Password'),
            ),
          ],
        ),
      ),
    );
  }
  // ---------------------------------------------------------------------------
  // HELPER WIDGET BUILDERS FOR REUSABLE ROWS
  // ---------------------------------------------------------------------------
  Widget _buildSwitchRow(
    IconData icon,
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
    Color activeColor,
  ) {
    return _buildRowLayout(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: activeColor,
      ),
    );
  }
  Widget _buildRowLayout({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget trailing,
  }) {
    final textPrimary = ThemeService.instance.textPrimary;
    final textSecondary = ThemeService.instance.textSecondary;
    final inputBg = ThemeService.instance.inputBackground;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: inputBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: textSecondary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: textPrimary),
                  child: Text(title),
                ),
                const SizedBox(height: 2),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  style: TextStyle(fontSize: 11, color: textSecondary),
                  child: Text(subtitle),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          trailing,
        ],
      ),
    );
  }
}