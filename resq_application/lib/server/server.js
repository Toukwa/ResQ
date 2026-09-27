const express = require('express');
const mysql = require('mysql2/promise');
const http = require('http');
const { Server } = require('socket.io');
const bcrypt = require('bcryptjs');
const cors = require('cors');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const nodemailer = require('nodemailer');
const crypto = require('crypto');
const PDFDocument = require('pdfkit');

// Nodemailer SMTP Transporter setup
let mailTransporter = null;

async function getMailTransporter() {
  if (mailTransporter) return mailTransporter;

  if (process.env.SMTP_HOST && process.env.SMTP_USER) {
    mailTransporter = nodemailer.createTransport({
      host: process.env.SMTP_HOST,
      port: Number(process.env.SMTP_PORT || 587),
      secure: process.env.SMTP_SECURE === 'true',
      auth: {
        user: process.env.SMTP_USER,
        pass: process.env.SMTP_PASS
      }
    });
    console.log('[SMTP] Nodemailer configured with host:', process.env.SMTP_HOST);
  } else {
    try {
      const testAccount = await nodemailer.createTestAccount();
      mailTransporter = nodemailer.createTransport({
        host: 'smtp.ethereal.email',
        port: 587,
        secure: false,
        auth: {
          user: testAccount.user,
          pass: testAccount.pass
        }
      });
      console.log('[SMTP] Test Ethereal SMTP account created:', testAccount.user);
    } catch (e) {
      console.warn('[SMTP] Could not create Ethereal test SMTP, logging OTPs locally:', e.message);
    }
  }

  return mailTransporter;
}

async function sendMfaEmail(toEmail, otpCode, userName) {
  const htmlBody = `
    <div style="font-family: Arial, sans-serif; padding: 24px; background-color: #f8fafc; color: #0f172a;">
      <div style="max-width: 480px; margin: 0 auto; background: #ffffff; padding: 32px; border-radius: 12px; border: 1px solid #e2e8f0; box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.05);">
        <div style="text-align: center; margin-bottom: 20px;">
          <h2 style="color: #ff6b00; margin: 0; font-size: 24px;">ResQ EOC</h2>
          <p style="color: #94a3b8; font-size: 13px; margin-top: 4px;">Emergency Operations Center</p>
        </div>
        <h3 style="font-size: 16px; color: #1e293b;">Hello ${userName || 'Admin'},</h3>
        <p style="font-size: 14px; color: #475569; line-height: 1.5;">Your Multi-Factor Authentication (MFA) security code is:</p>
        <div style="background: #fff7ed; border: 1.5px dashed #ff6b00; padding: 18px; border-radius: 10px; text-align: center; margin: 24px 0;">
          <span style="font-size: 34px; font-weight: 800; letter-spacing: 10px; color: #ff6b00;">${otpCode}</span>
        </div>
        <p style="font-size: 12px; color: #64748b; margin-bottom: 0;">This code is valid for 5 minutes. If you did not request this login attempt, please contact system administration immediately.</p>
      </div>
    </div>
  `;

  const mailOptions = {
    from: '"ResQ Security" <no-reply@resq-eoc.gov.ph>',
    to: toEmail,
    subject: `ResQ MFA Verification Code: ${otpCode}`,
    html: htmlBody,
    text: `Your ResQ MFA verification code is: ${otpCode}. It expires in 5 minutes.`
  };

  try {
    const transporter = await getMailTransporter();
    if (transporter) {
      const info = await transporter.sendMail(mailOptions);
      console.log(`\n======================================================`);
      console.log(`[MFA EMAIL DISPATCHED] Real OTP Code [${otpCode}] sent to -> ${toEmail}`);
      console.log(`[SMTP MessageID]: ${info.messageId}`);
      if (nodemailer.getTestMessageUrl(info)) {
        console.log(`[ONLINE PREVIEW LINK]: ${nodemailer.getTestMessageUrl(info)}`);
      }
      console.log(`======================================================\n`);
    } else {
      console.log(`\n[MFA OTP GENERATED] Real OTP Code for ${toEmail}: [${otpCode}]\n`);
    }
  } catch (err) {
    console.error(`[MFA EMAIL ERROR] Error sending email to ${toEmail}:`, err.message);
    console.log(`[MFA OTP FALLBACK PRINT] Code for ${toEmail}: [${otpCode}]`);
  }
}

const app = express();
const server = http.createServer(app);
const io = new Server(server, { cors: { origin: '*' } });

app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(cors());

// Ensure uploads directory exists and serve statically
const uploadsDir = path.join(__dirname, 'uploads');
if (!fs.existsSync(uploadsDir)) {
  fs.mkdirSync(uploadsDir, { recursive: true });
}
app.use('/uploads', express.static(uploadsDir));

// Multer Storage Configuration
const storage = multer.diskStorage({
  destination: (req, file, cb) => {
    cb(null, uploadsDir);
  },
  filename: (req, file, cb) => {
    cb(null, Date.now() + path.extname(file.originalname));
  }
});
const upload = multer({ storage });

// Database Connection Pool
const db = mysql.createPool({
  host: 'localhost',
  user: 'root',
  password: '',
  database: 'resq_db',
  waitForConnections: true,
  connectionLimit: 10,
  queueLimit: 0
});

// ==========================================
// DATA PRIVACY & SANITIZATION UTILITIES
// ==========================================
function sanitizeResidentData(data) {
  if (!data || typeof data !== 'object') return data;
  const sanitized = Array.isArray(data) ? [...data] : { ...data };

  // Strip sensitive resident PII, preserving structural IDs
  const sensitiveKeys = ['first_name', 'last_name', 'name', 'phone', 'email', 'address', 'password', 'password_hash'];
  
  for (const key in sanitized) {
    if (sensitiveKeys.includes(key.toLowerCase())) {
      delete sanitized[key];
    } else if (typeof sanitized[key] === 'object') {
      sanitized[key] = sanitizeResidentData(sanitized[key]);
    }
  }
  return sanitized;
}

// ==========================================
// CENTRALIZED SYSTEM LOGGING ENGINE
// ==========================================
async function logSystemEvent({ userId = null, role = 'SYSTEM', action, entityType, entityId = null, ip = null, status = 'SUCCESS', details = null }) {
  try {
    const sanitizedDetails = typeof details === 'object' 
      ? JSON.stringify(sanitizeResidentData(details)) 
      : details;

    const sql = `
      INSERT INTO system_logs (user_ID, user_role, action, entity_type, entity_id, ip_address, status, details)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `;
    const [result] = await db.query(sql, [userId, role, action, entityType, entityId, ip, status, sanitizedDetails]);

    // Broadcast live timeline update via Socket.io
    io.emit('refreshActivityLogsEvent', {
      log_id: result.insertId,
      user_ID: userId,
      user_role: role,
      action,
      entity_type: entityType,
      entity_id: entityId,
      status,
      details: sanitizedDetails,
      timestamp: new Date(),
      actor_display: role || 'System'
    });

    return result.insertId;
  } catch (err) {
    console.error('Audit Logging Error:', err);
  }
}

// Global Middleware to Audit Log Mutating HTTP Events (Excludes read-only GET polling)
app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    // Only log mutating / state-changing requests, ignore high-frequency GET polls
    if (req.originalUrl.startsWith('/api/') && req.method !== 'GET' &&
        !req.originalUrl.startsWith('/api/telemetry/')) {
      const clientIp = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
      const user = req.user || {};
      
      logSystemEvent({
        userId: user.id || null,
        role: user.role || 'GUEST',
        action: `${req.method} ${req.baseUrl}${req.path}`,
        entityType: req.path.split('/')[2] || 'SYSTEM',
        ip: clientIp,
        status: res.statusCode < 400 ? 'SUCCESS' : 'FAILED',
        details: { statusCode: res.statusCode, durationMs: Date.now() - start }
      });
    }
  });
  next();
});

// ==========================================
// REST ENDPOINTS
// ==========================================

// ------------------------------------------
// USER SETTINGS ENDPOINTS
// ------------------------------------------

// Get Settings for User
app.get('/api/user/:userId/settings', async (req, res) => {
  const userId = req.params.userId;
  try {
    const [rows] = await db.query('SELECT * FROM user_settings WHERE user_ID = ?', [userId]);
    
    const defaultSettings = {
      theme_mode: 'Light',
      reduced_motion: 0,
      critical_emergency_alerts: 1,
      unit_status_updates: 1,
      incident_updates: 1,
      system_notifications: 0,
      sound_alerts: 1,
      email_notifications: 1,
      sms_alerts: 0,
      map_display_style: 'Standard',
      auto_center_on_incident: 1,
      show_unit_labels: 1,
      show_route_lines: 1,
      mfa_enabled: 1,
      session_timeout: '15 min',
      auto_logout: 1,
      activity_log_enabled: 1,
      emergency_broadcast: 1,
      data_retention_policy: 1,
      analytics_reporting: 1
    };

    // Return default fallback if settings record doesn't exist yet
    if (rows.length === 0) {
      return res.json({
        success: true,
        data: defaultSettings,
        settings: defaultSettings
      });
    }

    res.json({ success: true, data: rows[0], settings: rows[0] });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Save or Update Settings (UPSERT with field merging)
app.put('/api/user/:userId/settings', async (req, res) => {
  const userId = req.params.userId;
  const settings = req.body;

  try {
    // 1. Fetch current settings (or defaults) to cleanly support partial updates
    const [existing] = await db.query('SELECT * FROM user_settings WHERE user_ID = ?', [userId]);
    const current = existing.length > 0 ? existing[0] : {
      theme_mode: 'Light',
      reduced_motion: 0,
      critical_emergency_alerts: 1,
      unit_status_updates: 1,
      incident_updates: 1,
      system_notifications: 0,
      sound_alerts: 1,
      email_notifications: 1,
      sms_alerts: 0,
      map_display_style: 'Standard',
      auto_center_on_incident: 1,
      show_unit_labels: 1,
      show_route_lines: 1,
      mfa_enabled: 1,
      session_timeout: '15 min',
      auto_logout: 1,
      activity_log_enabled: 1,
      emergency_broadcast: 1,
      data_retention_policy: 1,
      analytics_reporting: 1
    };

    const boolVal = (field) => (settings[field] !== undefined ? (settings[field] ? 1 : 0) : current[field]);
    const strVal = (field) => (settings[field] !== undefined ? settings[field] : current[field]);

    const sql = `
      INSERT INTO user_settings (
        user_ID, theme_mode, reduced_motion, critical_emergency_alerts, 
        unit_status_updates, incident_updates, system_notifications, 
        sound_alerts, email_notifications, sms_alerts, map_display_style, 
        auto_center_on_incident, show_unit_labels, show_route_lines, 
        mfa_enabled, session_timeout, auto_logout, activity_log_enabled, 
        emergency_broadcast, data_retention_policy, analytics_reporting
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON DUPLICATE KEY UPDATE
        theme_mode = VALUES(theme_mode),
        reduced_motion = VALUES(reduced_motion),
        critical_emergency_alerts = VALUES(critical_emergency_alerts),
        unit_status_updates = VALUES(unit_status_updates),
        incident_updates = VALUES(incident_updates),
        system_notifications = VALUES(system_notifications),
        sound_alerts = VALUES(sound_alerts),
        email_notifications = VALUES(email_notifications),
        sms_alerts = VALUES(sms_alerts),
        map_display_style = VALUES(map_display_style),
        auto_center_on_incident = VALUES(auto_center_on_incident),
        show_unit_labels = VALUES(show_unit_labels),
        show_route_lines = VALUES(show_route_lines),
        mfa_enabled = VALUES(mfa_enabled),
        session_timeout = VALUES(session_timeout),
        auto_logout = VALUES(auto_logout),
        activity_log_enabled = VALUES(activity_log_enabled),
        emergency_broadcast = VALUES(emergency_broadcast),
        data_retention_policy = VALUES(data_retention_policy),
        analytics_reporting = VALUES(analytics_reporting);
    `;

    const values = [
      userId,
      strVal('theme_mode'),
      boolVal('reduced_motion'),
      boolVal('critical_emergency_alerts'),
      boolVal('unit_status_updates'),
      boolVal('incident_updates'),
      boolVal('system_notifications'),
      boolVal('sound_alerts'),
      boolVal('email_notifications'),
      boolVal('sms_alerts'),
      strVal('map_display_style'),
      boolVal('auto_center_on_incident'),
      boolVal('show_unit_labels'),
      boolVal('show_route_lines'),
      boolVal('mfa_enabled'),
      strVal('session_timeout'),
      boolVal('auto_logout'),
      boolVal('activity_log_enabled'),
      boolVal('emergency_broadcast'),
      boolVal('data_retention_policy'),
      boolVal('analytics_reporting')
    ];

    await db.query(sql, values);

    // System Logging Engine Entry
    await logSystemEvent({
      userId: userId,
      role: 'USER',
      action: 'UPDATE_SETTINGS',
      entityType: 'USER_SETTINGS',
      entityId: userId,
      ip: req.ip,
      status: 'SUCCESS',
      details: { updatedFields: Object.keys(settings) }
    });

    res.json({ success: true, message: 'Settings updated successfully' });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Change Password for User
app.post('/api/user/:userId/change-password', async (req, res) => {
  const userId = req.params.userId;
  const { currentPassword, newPassword } = req.body;

  if (!currentPassword || !newPassword) {
    return res.status(400).json({ success: false, error: 'Current password and new password are required.' });
  }

  if (newPassword.length < 6) {
    return res.status(400).json({ success: false, error: 'New password must be at least 6 characters.' });
  }

  try {
    const [users] = await db.query('SELECT Citizen_ID, userName, pass_hash FROM resident WHERE Citizen_ID = ?', [userId]);
    if (users.length === 0) {
      return res.status(404).json({ success: false, error: 'User not found.' });
    }

    const user = users[0];
    const passwordMatch = await bcrypt.compare(currentPassword, user.pass_hash);
    if (!passwordMatch) {
      return res.status(401).json({ success: false, error: 'Incorrect current password.' });
    }

    const newHashedPassword = await bcrypt.hash(newPassword, 10);
    await db.query('UPDATE resident SET pass_hash = ? WHERE Citizen_ID = ?', [newHashedPassword, userId]);

    await logSystemEvent({
      userId: userId,
      role: 'USER',
      action: 'CHANGE_PASSWORD',
      entityType: 'USER',
      entityId: userId,
      ip: req.ip,
      status: 'SUCCESS',
      details: { message: 'Password updated successfully' }
    });

    res.json({ success: true, message: 'Password changed successfully.' });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Get User Profile
app.get('/api/user/:userId/profile', async (req, res) => {
  const userId = req.params.userId;
  try {
    const [users] = await db.query(`
      SELECT 
        r.Citizen_ID as id,
        r.Citizen_ID,
        r.userName as name,
        r.userName,
        r.email,
        r.contactNo as phone,
        r.contactNo,
        r.role,
        r.deptID,
        COALESCE(d.deptName, 'Central Operations') as agency
      FROM resident r
      LEFT JOIN department d ON r.deptID = d.dept_ID
      WHERE r.Citizen_ID = ?
    `, [userId]);
    if (users.length === 0) {
      return res.status(404).json({ success: false, error: 'User not found' });
    }
    res.json({ success: true, user: users[0] });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// ------------------------------------------
// GENERAL REST ENDPOINTS
// ------------------------------------------

// 1. Audit-Driven Activity Timeline Feed
app.get('/api/activity-timeline', async (req, res) => {
  try {
    const limit = parseInt(req.query.limit) || 50;
    const [rows] = await db.query('SELECT * FROM vw_activity_timeline LIMIT ?', [limit]);
    res.json({ success: true, data: rows });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Dashboard Metrics
app.get('/api/admin/dashboard-metrics', async (req, res) => {
  try {
    const [totalIncidents] = await db.query('SELECT COUNT(*) as count FROM emergency_request');
    const [activeIncidents] = await db.query(
      "SELECT COUNT(*) as count FROM emergency_request WHERE LOWER(reqStatus) IN ('pending', 'in_progress', 'en route', 'active')"
    );
    const [totalVehicles] = await db.query('SELECT COUNT(*) as count FROM response_vehicle');
    
    // Status breakdown for vehicles
    const [vehBreakdown] = await db.query(`
      SELECT 
        SUM(CASE WHEN LOWER(status) = 'available' THEN 1 ELSE 0 END) as availableUnits,
        SUM(CASE WHEN LOWER(status) IN ('en route', 'en_route') THEN 1 ELSE 0 END) as enRouteUnits,
        SUM(CASE WHEN LOWER(status) IN ('busy', 'on scene', 'dispatched') THEN 1 ELSE 0 END) as busyUnits
      FROM response_vehicle
    `);

    // Department unit proportions
    const [deptResults] = await db.query(`
      SELECT 
        d.deptName,
        SUM(CASE WHEN LOWER(v.status) = 'available' THEN 1 ELSE 0 END) as available_units,
        COUNT(v.vehicle_ID) as total_units
      FROM department d
      LEFT JOIN response_vehicle v ON d.dept_ID = v.dept_ID
      GROUP BY d.dept_ID, d.deptName
    `);

    let pnpRatio = "0/0";
    let bfpRatio = "0/0";
    let cdrrmoRatio = "0/0";

    deptResults.forEach(row => {
      if (!row.deptName) return;
      const name = row.deptName.toUpperCase();
      const ratioString = `${row.available_units || 0}/${row.total_units || 0}`;
      if (name.includes('PNP')) pnpRatio = ratioString;
      if (name.includes('BFP')) bfpRatio = ratioString;
      if (name.includes('CDRRMO')) cdrrmoRatio = ratioString;
    });

    const [totalUsers] = await db.query('SELECT COUNT(*) as count FROM resident');

    const availableUnits = Number(vehBreakdown[0].availableUnits) || 0;
    const enRouteUnits = Number(vehBreakdown[0].enRouteUnits) || 0;
    const busyUnits = Number(vehBreakdown[0].busyUnits) || 0;
    const activeIncidentsCount = Number(activeIncidents[0].count) || 0;

    res.json({
      success: true,
      data: {
        availableUnits,
        enRouteUnits,
        busyUnits,
        activeIncidentsCount,
        pnpRatio,
        bfpRatio,
        cdrrmoRatio,
        totalIncidents: totalIncidents[0].count,
        activeIncidents: activeIncidentsCount,
        totalVehicles: totalVehicles[0].count,
        activeVehicles: availableUnits,
        totalUsers: totalUsers[0].count
      }
    });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Vehicles with Departments
app.get('/api/admin/vehicles-with-dept', async (req, res) => {
  try {
    const [rows] = await db.query(`
      SELECT v.*,
             COALESCE(v.plate_no, CONCAT('Unit #', v.vehicle_ID)) AS plate_no,
             COALESCE(v.vehicle_type, 'Unassigned Type') AS vehicle_type,
             COALESCE(d.deptName, 'Unassigned') AS deptName,
             l.latitude, l.longitude, l.speed_kph, l.course_deg,
             l.altitude_m, l.satellites, l.fix_timestamp, l.source,
             CASE
               WHEN l.fix_timestamp IS NULL THEN 'Offline'
               WHEN TIMESTAMPDIFF(SECOND, l.fix_timestamp, NOW()) >= 600 OR TIMESTAMPDIFF(SECOND, l.fix_timestamp, UTC_TIMESTAMP()) >= 600 THEN 'Offline'
               ELSE v.status
             END AS computed_status
      FROM response_vehicle v 
      LEFT JOIN department d ON v.dept_ID = d.dept_ID
      LEFT JOIN vehicle_location l ON v.vehicle_ID = l.vehicle_ID
      ORDER BY v.vehicle_ID
    `);
    for (const incident of rows) {
      const reqId = incident.Req_ID || incident.id;
      const [deptRows] = await db.query(
        'SELECT dept_name, status FROM incident_department_status WHERE req_ID = ?',
        [reqId]
      );
      if (deptRows.length === 0) {
        const involved = getInvolvedDepartments(incident.incType || incident.type);
        incident.department_statuses = involved.map(d => ({ dept_name: d, status: incident.reqStatus || incident.status || 'Pending' }));
      } else {
        incident.department_statuses = deptRows;
      }
    }
    res.json({ success: true, data: rows });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

function generateUnassignedPlate() {
  const now = new Date();
  const hh = String(now.getHours()).padStart(2, '0');
  const mm = String(now.getMinutes()).padStart(2, '0');
  const yyyy = now.getFullYear();
  return `VHE-${hh}${mm}${yyyy}`;
}

// GPS telemetry for ESP32 trackers. The tracker authenticates as a device;
// department ownership is always derived from response_vehicle.dept_ID.
// GPS telemetry for ESP32 trackers using Approach 2 (Hardware ID + Secret API Key).
// Tracker identifies by physical MAC/HardwareID and authenticates with secret api_key.
// Department admins assign plate_no, vehicle_type, and dept_ID via the ResQ Admin Web App.
async function receiveVehicleLocation(req, res, source) {
  const { vehicleId, hardwareId: rawHardwareId, timestamp, latitude, longitude, speedKph, courseDeg, altitudeM, satellites } = req.body;
  const hardwareId = rawHardwareId || req.get('X-Hardware-ID') || (vehicleId ? `VEHICLE-${vehicleId}` : null);
  const deviceKey = req.get('X-Device-Key') || req.body.deviceKey;
  const lat = Number(latitude);
  const lon = Number(longitude);

  if (!Number.isFinite(lat) || !Number.isFinite(lon) ||
      lat < -90 || lat > 90 || lon < -180 || lon > 180 || !deviceKey) {
    return res.status(400).json({ success: false, error: 'Invalid telemetry payload' });
  }

  try {
    let resolvedVehicleId = vehicleId ? Number(vehicleId) : null;
    let deptId = null;

    // 1. Look up device by hardwareId or vehicleId or api_key
    let deviceRow = null;
    if (hardwareId) {
      const [byHw] = await db.query(
        `SELECT gd.vehicle_ID, gd.api_key, v.dept_ID
         FROM response_vehicle v
         LEFT JOIN gps_device gd ON v.vehicle_ID = gd.vehicle_ID
         WHERE v.HardwareID_mapping = ?`,
        [hardwareId]
      );
      if (byHw.length > 0) deviceRow = byHw[0];
    }

    if (!deviceRow && resolvedVehicleId) {
      const [byVid] = await db.query(
        `SELECT gd.vehicle_ID, gd.api_key, v.dept_ID
         FROM response_vehicle v
         LEFT JOIN gps_device gd ON v.vehicle_ID = gd.vehicle_ID
         WHERE v.vehicle_ID = ?`,
        [resolvedVehicleId]
      );
      if (byVid.length > 0) deviceRow = byVid[0];
    }

    if (!deviceRow) {
      const [byKey] = await db.query(
        `SELECT gd.vehicle_ID, gd.api_key, v.dept_ID
         FROM gps_device gd
         INNER JOIN response_vehicle v ON v.vehicle_ID = gd.vehicle_ID
         WHERE gd.api_key = ?`,
        [deviceKey]
      );
      if (byKey.length > 0) deviceRow = byKey[0];
    }

    // 2. Auto-provision unassigned unit if not found
    if (!deviceRow) {
      const hwTag = hardwareId || `MAC-${Date.now()}`;
      const defaultPlate = generateUnassignedPlate();

      // Clean up any stale orphaned gps_device key to prevent ER_DUP_ENTRY if response_vehicle was deleted manually
      if (deviceKey) {
        await db.query('DELETE FROM gps_device WHERE api_key = ?', [String(deviceKey)]);
      }

      const [insRes] = await db.query(
        `INSERT INTO response_vehicle (plate_no, vehicle_type, dept_ID, HardwareID_mapping, status)
         VALUES (?, 'Unassigned', NULL, ?, 'Available')`,
        [defaultPlate, hwTag]
      );
      resolvedVehicleId = insRes.insertId;

      await db.query(
        `INSERT INTO gps_device (vehicle_ID, api_key, sms_secret, is_active)
         VALUES (?, ?, 'resq_sms_secret', 1)
         ON DUPLICATE KEY UPDATE api_key = VALUES(api_key)`,
        [resolvedVehicleId, String(deviceKey)]
      );

      deptId = null;
      console.log(`[+] Auto-detected & created unassigned vehicle #${resolvedVehicleId} (Hardware ID: ${hwTag})`);
      io.emit('refreshManagementData', { type: 'UNASSIGNED_DETECTED', vehicleId: resolvedVehicleId });
    } else {
      if (deviceRow.api_key && !safeSecretEquals(deviceRow.api_key, String(deviceKey))) {
        return res.status(401).json({ success: false, error: 'Unauthorized device key' });
      }
      resolvedVehicleId = deviceRow.vehicle_ID;
      deptId = deviceRow.dept_ID;
    }

    const fixTime = timestamp ? new Date(timestamp) : new Date();
    if (Number.isNaN(fixTime.getTime())) {
      return res.status(400).json({ success: false, error: 'Invalid timestamp' });
    }

    await db.query(
      `INSERT INTO vehicle_location
         (vehicle_ID, latitude, longitude, speed_kph, course_deg, altitude_m, satellites, fix_timestamp, received_at, source)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW(), ?)
       ON DUPLICATE KEY UPDATE
         latitude = VALUES(latitude), longitude = VALUES(longitude), speed_kph = VALUES(speed_kph),
         course_deg = VALUES(course_deg), altitude_m = VALUES(altitude_m), satellites = VALUES(satellites),
         fix_timestamp = VALUES(fix_timestamp), received_at = NOW(), source = VALUES(source)`,
      [resolvedVehicleId, lat, lon, finiteOrNull(speedKph), finiteOrNull(courseDeg),
       finiteOrNull(altitudeM), finiteOrNull(satellites), fixTime, source]
    );

    io.emit('vehicleLocationUpdated', {
      vehicle_ID: resolvedVehicleId,
      dept_ID: deptId,
      latitude: lat,
      longitude: lon,
      speed_kph: finiteOrNull(speedKph),
      course_deg: finiteOrNull(courseDeg),
      fix_timestamp: fixTime.toISOString(),
      source
    });

    console.log(`ðŸ“¡ [GPS Telemetry] Vehicle ${resolvedVehicleId} (${source}): lat=${lat}, lon=${lon}, speed=${speedKph || 0}km/h, sats=${satellites || 0}`);
    return res.json({ success: true, vehicleId: resolvedVehicleId, departmentId: deptId });
  } catch (err) {
    console.error('Vehicle telemetry error:', err);
    return res.status(500).json({ success: false, error: 'Could not save telemetry' });
  }
}

app.post('/api/telemetry/vehicle-location', (req, res) => receiveVehicleLocation(req, res, 'wifi'));

// SMS/chat gateway adapter. Forward an inbound text as { message: "RESQ1,..." }.
// Expected format: RESQ1,vehicleId,unixSeconds,latitude,longitude,speedKph,courseDeg,altitudeM,satellites,smsSecret
app.post('/api/telemetry/sms-location', async (req, res) => {
  const message = String(req.body.message || '').trim();
  const parts = message.split(',').map(part => part.trim());
  if (parts.length !== 10 || parts[0] !== 'RESQ1') {
    return res.status(400).json({ success: false, error: 'Invalid ResQ SMS format' });
  }

  const [_, vehicleId, unixSeconds, latitude, longitude, speedKph, courseDeg, altitudeM, satellites, smsSecret] = parts;
  try {
    const [devices] = await db.query(
      'SELECT sms_secret FROM gps_device WHERE vehicle_ID = ? AND is_active = 1', [vehicleId]
    );
    if (!devices[0] || !safeSecretEquals(devices[0].sms_secret, smsSecret)) {
      return res.status(401).json({ success: false, error: 'Unknown SMS tracker' });
    }
    req.body = {
      vehicleId, latitude, longitude, speedKph, courseDeg, altitudeM, satellites,
      timestamp: new Date(Number(unixSeconds) * 1000).toISOString(),
      deviceKey: await db.query('SELECT api_key FROM gps_device WHERE vehicle_ID = ?', [vehicleId]).then(([rows]) => rows[0].api_key)
    };
    return receiveVehicleLocation(req, res, 'sms');
  } catch (err) {
    console.error('SMS telemetry error:', err);
    return res.status(500).json({ success: false, error: 'Could not process SMS telemetry' });
  }
});

function safeSecretEquals(expected, supplied) {
  const expectedBuffer = Buffer.from(String(expected));
  const suppliedBuffer = Buffer.from(String(supplied));
  return expectedBuffer.length === suppliedBuffer.length && crypto.timingSafeEqual(expectedBuffer, suppliedBuffer);
}

function finiteOrNull(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

// Active Incidents List with full joined telemetry
app.get('/api/admin/active-incidents-list', async (req, res) => {
  try {
    const [rows] = await db.query(`
      SELECT 
        e.*,
        e.Req_ID as id,
        e.incType as type,
        e.reqStatus as status,
        DATE_FORMAT(e.SOS_timeStamp, '%H:%i') as timeString,
        r.userName as residentName,
        r.userName,
        r.contactNo,
        d.Disp_ID as dispatchId,
        d.Dispatch_timeStamp as dispatchTimestamp,
        d.status as dispatchStatus,
        v.plate_no,
        v.vehicle_type,
        v.status as vehicleStatus,
        dept.deptName,
        dept.agencyType
      FROM emergency_request e 
      LEFT JOIN resident r ON e.Citizen_ID = r.Citizen_ID 
      LEFT JOIN (
        SELECT d1.*
        FROM dispatch_event d1
        INNER JOIN (
          SELECT Req_ID, MAX(Disp_ID) as max_id
          FROM dispatch_event
          GROUP BY Req_ID
        ) d2 ON d1.Disp_ID = d2.max_id
      ) d ON e.Req_ID = d.Req_ID
      LEFT JOIN response_vehicle v ON d.Vehicle_ID = v.vehicle_ID
      LEFT JOIN department dept ON v.dept_ID = dept.dept_ID
      ORDER BY e.SOS_timeStamp DESC
    `);
    for (const incident of rows) {
      const [deptRows] = await db.query(
        'SELECT dept_name, status FROM incident_department_status WHERE req_ID = ?',
        [incident.Req_ID]
      );
      if (deptRows.length === 0) {
        const involved = getInvolvedDepartments(incident.incType);
        incident.department_statuses = involved.map(d => ({ dept_name: d, status: incident.reqStatus || 'Pending' }));
      } else {
        incident.department_statuses = deptRows;
      }
    }
    res.json({ success: true, data: rows });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Activity Logs (Admin)
app.get('/api/admin/activity-logs', async (req, res) => {
  try {
    const limit = parseInt(req.query.limit) || 50;
    const [rows] = await db.query(`
      SELECT 
        sl.log_id,
        sl.user_ID,
        sl.user_role,
        sl.action,
        sl.entity_type,
        sl.entity_id,
        sl.status,
        sl.details,
        sl.ip_address,
        sl.timestamp,
        COALESCE(r.userName, sl.user_role, 'System') as actor_display,
        r.role as userRole
      FROM system_logs sl
      LEFT JOIN resident r ON sl.user_ID = r.Citizen_ID
      WHERE (sl.action NOT LIKE '% /api/%' AND sl.action NOT LIKE '% undefined%')
      ORDER BY sl.timestamp DESC, sl.log_id DESC
      LIMIT ?
    `, [limit]);
    res.json({ success: true, data: rows });
  } catch (err) {
    console.error('Activity logs error:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

// Export Audit Logs ZIP package (Full-Day PDF report in DESC order + Evidence Photos Folder)
app.get('/api/admin/export-audit-logs-zip', async (req, res) => {
  try {
    const targetDate = req.query.date || new Date().toISOString().split('T')[0];
    const startOfDay = `${targetDate} 00:00:00`;
    const endOfDay = `${targetDate} 23:59:59`;

    // 1. Fetch ALL system logs for the whole day ordered by DESCENDING timestamp (no limit!)
    const [logRows] = await db.query(`
      SELECT 
        sl.log_id,
        sl.user_ID,
        sl.user_role,
        sl.action,
        sl.entity_type,
        sl.entity_id,
        sl.status,
        sl.details,
        sl.ip_address,
        sl.timestamp,
        COALESCE(r.userName, sl.user_role, 'System') as actor_display,
        r.role as userRole
      FROM system_logs sl
      LEFT JOIN resident r ON sl.user_ID = r.Citizen_ID
      WHERE sl.timestamp >= ? AND sl.timestamp <= ?
        AND (sl.action NOT LIKE '% /api/%' AND sl.action NOT LIKE '% undefined%')
      ORDER BY sl.timestamp DESC, sl.log_id DESC
    `, [startOfDay, endOfDay]);

    // 2. Fetch ALL emergency requests created on that day with uploaded photos
    const [incidents] = await db.query(`
      SELECT Req_ID, incType, image_path, SOS_timeStamp
      FROM emergency_request
      WHERE SOS_timeStamp >= ? AND SOS_timeStamp <= ?
    `, [startOfDay, endOfDay]);

    // 3. Setup ZIP Archiver stream
    const { ZipArchive } = await import('archiver');
    const archive = new ZipArchive({ zlib: { level: 9 } });
    const zipFileName = `AuditLogs(${targetDate}).zip`;
    const pdfFileName = `AuditLogs(${targetDate}).pdf`;

    res.setHeader('Content-Type', 'application/zip');
    res.setHeader('Content-Disposition', `attachment; filename="${zipFileName}"`);

    archive.pipe(res);

    // 4. Generate PDF Document in memory using PDFKit
    const doc = new PDFDocument({ margin: 36, size: 'A4' });
    const pdfBuffers = [];
    doc.on('data', chunk => pdfBuffers.push(chunk));

    // PDF Header & Branding
    doc.fillColor('#FF5200').fontSize(18).text('ResQ Emergency Operations Center', { align: 'left' });
    doc.fillColor('#64748B').fontSize(10).text('OFFICIAL SYSTEM AUDIT LOG & COMPLIANCE REPORT', { align: 'left' });
    doc.moveDown(0.5);

    doc.strokeColor('#E2E8F0').lineWidth(1).moveTo(36, doc.y).lineTo(559, doc.y).stroke();
    doc.moveDown(0.8);

    doc.fillColor('#0F172A').fontSize(11).text(`Report Date: ${targetDate}`);
    doc.fillColor('#475569').fontSize(10).text(`Total Audit Records: ${logRows.length} event(s) (Full-Day Scope)`);
    doc.text(`Report Generated: ${new Date().toLocaleString()}`);
    doc.moveDown(1);

    if (logRows.length === 0) {
      doc.fillColor('#94A3B8').fontSize(12).text('No audit log records found for the selected date.', { align: 'center' });
    } else {
      // Table Header
      let y = doc.y;
      doc.rect(36, y, 523, 20).fill('#1E293B');
      doc.fillColor('#FFFFFF').fontSize(8);
      doc.text('ID', 42, y + 6, { width: 35 });
      doc.text('Timestamp', 80, y + 6, { width: 95 });
      doc.text('Actor / Role', 180, y + 6, { width: 100 });
      doc.text('Action / Event', 285, y + 6, { width: 110 });
      doc.text('Status', 400, y + 6, { width: 50 });
      doc.text('Details Payload', 455, y + 6, { width: 100 });
      doc.y = y + 24;

      // Render Rows in DESCENDING Order
      for (let i = 0; i < logRows.length; i++) {
        const log = logRows[i];
        if (doc.y > 750) {
          doc.addPage();
        }

        const currentY = doc.y;
        const isEven = i % 2 === 0;
        doc.rect(36, currentY, 523, 30).fill(isEven ? '#FFFFFF' : '#F8FAFC');

        const dateStr = log.timestamp ? new Date(log.timestamp).toLocaleString() : 'N/A';
        const actor = `${log.actor_display || 'System'} (${log.user_role || 'Sys'})`;
        const action = String(log.action || '').substring(0, 28);
        const status = String(log.status || 'INFO').toUpperCase();
        
        let detailsStr = '';
        if (log.details) {
          try {
            detailsStr = typeof log.details === 'object' ? JSON.stringify(log.details) : String(log.details);
          } catch (_) {
            detailsStr = String(log.details);
          }
        }
        const refStr = log.entity_type ? `${log.entity_type} #${log.entity_id || ''} ${detailsStr}` : detailsStr;

        doc.fillColor('#0F172A').fontSize(7.5);
        doc.text(String(log.log_id || (i + 1)), 42, currentY + 6, { width: 35 });
        doc.text(dateStr, 80, currentY + 6, { width: 95 });
        doc.text(actor, 180, currentY + 6, { width: 100 });
        doc.text(action, 285, currentY + 6, { width: 110 });

        const statusColor = status === 'SUCCESS' ? '#16A34A' : (status === 'FAILED' ? '#DC2626' : '#D97706');
        doc.fillColor(statusColor).text(status, 400, currentY + 6, { width: 50 });
        doc.fillColor('#475569').text(refStr.substring(0, 45), 455, currentY + 6, { width: 100 });

        doc.y = currentY + 32;
      }
    }

    doc.end();

    const pdfBuffer = await new Promise((resolve) => {
      doc.on('end', () => resolve(Buffer.concat(pdfBuffers)));
    });

    // Add PDF file to ZIP archive inside root folder
    const folderName = `AuditLogs(${targetDate})`;
    const pdfZipPath = `${folderName}/${pdfFileName}`;
    archive.append(pdfBuffer, { name: pdfZipPath });

    // 5. Add Evidence Photos to `evidence_photos/` folder inside root folder of ZIP
    const uploadDir = path.join(__dirname, 'uploads');
    let photoCount = 0;

    for (const inc of incidents) {
      if (inc.image_path) {
        const paths = String(inc.image_path).split(',');
        for (let idx = 0; idx < paths.length; idx++) {
          const rawPath = paths[idx].trim();
          if (!rawPath) continue;
          const cleanName = path.basename(rawPath);
          const fullPath = path.join(uploadDir, cleanName);

          if (fs.existsSync(fullPath)) {
            const ext = path.extname(cleanName) || '.jpg';
            const zipPhotoName = `${folderName}/evidence_photos/REQ-${String(inc.Req_ID).padStart(4, '0')}_photo${idx + 1}${ext}`;
            archive.file(fullPath, { name: zipPhotoName });
            photoCount++;
          }
        }
      }
    }

    console.log(`[ZIP EXPORT SUCCESS] Created ${zipFileName} containing ${logRows.length} logs & ${photoCount} evidence photos`);
    await archive.finalize();
  } catch (err) {
    console.error('[ZIP EXPORT ERROR]:', err);
    if (!res.headersSent) {
      res.status(500).json({ success: false, error: err.message });
    }
  }
});

// Incident Search
app.get('/api/admin/incidents/search', async (req, res) => {
  try {
    const query = req.query.q || '';
    const [rows] = await db.query(`
      SELECT 
        e.*,
        e.Req_ID as id,
        e.incType as type,
        e.reqStatus as status,
        DATE_FORMAT(e.SOS_timeStamp, '%H:%i') as timeString,
        r.userName as residentName,
        r.userName,
        r.contactNo,
        d.Disp_ID as dispatchId,
        d.Dispatch_timeStamp as dispatchTimestamp,
        v.plate_no,
        v.vehicle_type,
        dept.deptName,
        dept.agencyType
      FROM emergency_request e 
      LEFT JOIN resident r ON e.Citizen_ID = r.Citizen_ID 
      LEFT JOIN (
        SELECT d1.*
        FROM dispatch_event d1
        INNER JOIN (
          SELECT Req_ID, MAX(Disp_ID) as max_id
          FROM dispatch_event
          GROUP BY Req_ID
        ) d2 ON d1.Disp_ID = d2.max_id
      ) d ON e.Req_ID = d.Req_ID
      LEFT JOIN response_vehicle v ON d.Vehicle_ID = v.vehicle_ID
      LEFT JOIN department dept ON v.dept_ID = dept.dept_ID
      WHERE e.incType LIKE ? OR e.description LIKE ? OR r.userName LIKE ?
      ORDER BY e.SOS_timeStamp DESC
      LIMIT 50
    `, [`%${query}%`, `%${query}%`, `%${query}%`]);
    res.json({ success: true, data: rows });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Update Incident Status
app.post('/api/admin/update-status', async (req, res) => {
  const { reqId, status, department, dept } = req.body;
  try {
    const actingDept = department || dept || 'ALL';
    const syncResult = await syncIncidentDepartmentStatus(reqId, actingDept, status);

    if (status && status.toLowerCase() === 'completed') {
      await db.query(
        "UPDATE response_vehicle SET status = 'Available' WHERE vehicle_ID IN (SELECT vehicle_ID FROM dispatch_event WHERE Req_ID = ?)",
        [reqId]
      );
      await db.query(
        "UPDATE dispatch_event SET status = 'Completed' WHERE Req_ID = ?",
        [reqId]
      );
    }

    await logSystemEvent({
      action: 'STATUS_CHANGE',
      entityType: 'emergency_request',
      entityId: reqId,
      status: 'SUCCESS',
      details: { newStatus: status }
    });

    io.emit('refreshIncidentQueueEvent');
    io.emit('refreshManagementData');
    res.json({ success: true, ...syncResult });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Get Incident Dispatch Info
app.get('/api/admin/incident-dispatch/:reqId', async (req, res) => {
  try {
    const reqId = req.params.reqId;
    const [rows] = await db.query(`
      SELECT d.*, v.plate_no, v.vehicle_type, v.status as vehicleStatus
      FROM dispatch_event d
      LEFT JOIN response_vehicle v ON d.Vehicle_ID = v.vehicle_ID
      WHERE d.Req_ID = ?
      ORDER BY d.Dispatch_timeStamp DESC
      LIMIT 1
    `, [reqId]);
    res.json({ success: true, data: rows.length > 0 ? rows[0] : null });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// GET all dispatched vehicles & live telemetry assigned specifically to a citizen's emergency request
app.get('/api/citizen/dispatched-vehicles/:reqId', async (req, res) => {
  try {
    const reqId = req.params.reqId;
    const [rows] = await db.query(`
      SELECT 
        d.Disp_ID as dispatchId,
        d.Req_ID as reqId,
        d.Vehicle_ID as vehicleId,
        d.Dispatch_timeStamp as dispatchTime,
        d.status as dispatchStatus,
        v.plate_no,
        v.vehicle_type,
        COALESCE(v.status, 'Dispatched') as vehicleStatus,
        dept.deptName,
        dept.agencyType,
        vl.latitude,
        vl.longitude,
        vl.speed_kph,
        vl.course_deg,
        vl.fix_timestamp
      FROM dispatch_event d
      INNER JOIN response_vehicle v ON d.Vehicle_ID = v.vehicle_ID
      LEFT JOIN department dept ON v.dept_ID = dept.dept_ID
      LEFT JOIN vehicle_location vl ON v.vehicle_ID = vl.vehicle_ID
      WHERE d.Req_ID = ? AND d.status != 'Cancelled'
      ORDER BY d.Dispatch_timeStamp DESC
    `, [reqId]);

    res.json({ success: true, data: rows });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// 2. Incident Emergency Creation (with Multer photo upload support)
app.post('/api/emergency-requests', upload.any(), async (req, res) => {
  const { resident_id, type, latitude, longitude, description, Citizen_ID, incType } = req.body;
  // Support both parameter naming conventions
  const finalCitizenId = resident_id || Citizen_ID;
  const finalIncType = type || incType;
  let uploadedPaths = []; if (req.files && Array.isArray(req.files) && req.files.length > 0) { uploadedPaths = req.files.map(f => `/uploads/${f.filename}`); } else if (req.file) { uploadedPaths = [`/uploads/${req.file.filename}`]; } const imagePath = uploadedPaths.length > 0 ? uploadedPaths.join(',') : null;
  
  try {
    const [result] = await db.query(
      'INSERT INTO emergency_request (Citizen_ID, incType, latitude, longitude, reqStatus, description, image_path) VALUES (?, ?, ?, ?, "Pending", ?, ?)',
      [finalCitizenId, finalIncType, latitude, longitude, description || '', imagePath]
    );

    const emergencyId = result.insertId;

    // Seed involved department statuses
    try {
      const involved = getInvolvedDepartments(finalIncType);
      for (const dept of involved) {
        await db.query(
          'INSERT IGNORE INTO incident_department_status (req_ID, dept_name, status) VALUES (?, ?, "Pending")',
          [emergencyId, dept]
        );
      }
    } catch (deptErr) {
      console.error('Error seeding incident_department_status:', deptErr.message);
    }

    // Direct Correlation Logging with Data Privacy
    await logSystemEvent({
      userId: finalCitizenId,
      role: 'RESIDENT',
      action: 'EMERGENCY_REQUEST_CREATED',
      entityType: 'emergency_request',
      entityId: emergencyId,
      ip: req.ip,
      status: 'SUCCESS',
      details: { type: finalIncType, location: { latitude, longitude } }
    });

    // Create notifications for all admins
    try {
      const [admins] = await db.query("SELECT Citizen_ID FROM resident WHERE role IN ('Admin', 'Superadmin')");
      for (const admin of admins) {
        await db.query(
          'INSERT INTO notifications (recipient_ID, title, message, notification_type, req_ID, is_read, timestamp) VALUES (?, ?, ?, ?, ?, 0, NOW())',
          [admin.Citizen_ID, `New Emergency: ${finalIncType}`, `A new ${finalIncType} emergency request (#${emergencyId}) has been reported.`, 'EMERGENCY', emergencyId]
        );
      }
      io.emit('newNotification', { type: 'EMERGENCY', emergencyId, incType: finalIncType });
    } catch (notifErr) {
      console.error('Error creating emergency notification:', notifErr);
    }

    io.emit('refreshIncidentQueueEvent');
    io.emit('refreshMediaGalleryEvent');
    res.json({ success: true, emergency_id: emergencyId });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// In-memory store for active MFA verification codes
const activeMfaStore = new Map();

// ==========================================
// TRUSTED DEVICE (REMEMBER THIS DEVICE) API
// ==========================================

// Ensure trusted_devices table exists on first run
async function ensureTrustedDevicesTable() {
  try {
    await db.query(`
      CREATE TABLE IF NOT EXISTS trusted_devices (
        id INT AUTO_INCREMENT PRIMARY KEY,
        user_ID INT NOT NULL,
        device_token_hash VARCHAR(64) NOT NULL UNIQUE,
        device_label VARCHAR(120) DEFAULT NULL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        expires_at DATETIME NOT NULL,
        last_used_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_user (user_ID),
        INDEX idx_token (device_token_hash)
      )
    `);
  } catch (err) {
    console.error('[trusted_devices] Table init error:', err.message || err);
  }
}
ensureTrustedDevicesTable();

// Ensure incident_department_status table exists
async function ensureIncidentDeptStatusTable() {
  try {
    await db.query(`
      CREATE TABLE IF NOT EXISTS incident_department_status (
        id INT AUTO_INCREMENT PRIMARY KEY,
        req_ID INT NOT NULL,
        dept_name VARCHAR(50) NOT NULL,
        status VARCHAR(50) NOT NULL DEFAULT 'Pending',
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        UNIQUE KEY idx_req_dept (req_ID, dept_name)
      )
    `);
  } catch (err) {
    console.error('[incident_department_status] Table init error:', err.message || err);
  }
}
ensureIncidentDeptStatusTable();

// Extract involved departments from emergency type string
function getInvolvedDepartments(incType) {
  if (!incType) return ['BFP', 'PNP', 'CDRRMO'];
  const t = String(incType).toLowerCase();
  const depts = new Set();

  const parts = t.split(/[,/;+&]+/);
  for (const p of parts) {
    const str = p.trim();
    if (str.includes('fire') || str.includes('arson') || str.includes('explosion') || str.includes('bfp')) {
      depts.add('BFP');
    }
    if (str.includes('crime') || str.includes('accident') || str.includes('police') || str.includes('violence') || str.includes('theft') || str.includes('robbery') || str.includes('assault') || str.includes('homicide') || str.includes('murder') || str.includes('pnp')) {
      depts.add('PNP');
    }
    if (str.includes('medical') || str.includes('rescue') || str.includes('disaster') || str.includes('flood') || str.includes('earthquake') || str.includes('landslide') || str.includes('health') || str.includes('injury') || str.includes('storm') || str.includes('typhoon') || str.includes('cdrrmo')) {
      depts.add('CDRRMO');
    }
  }

  if (depts.size === 0) {
    if (t.includes('fire') || t.includes('bfp')) depts.add('BFP');
    if (t.includes('police') || t.includes('crime') || t.includes('pnp')) depts.add('PNP');
    if (t.includes('medical') || t.includes('rescue') || t.includes('cdrrmo')) depts.add('CDRRMO');
  }

  if (depts.size === 0) {
    depts.add('CDRRMO');
  }

  return Array.from(depts);
}

function normalizeDepartmentName(deptStr) {
  if (!deptStr) return 'ALL';
  const s = String(deptStr).toUpperCase().trim();
  if (s.includes('BFP') || s.includes('FIRE')) return 'BFP';
  if (s.includes('PNP') || s.includes('POLICE')) return 'PNP';
  if (s.includes('CDRRMO') || s.includes('DISASTER') || s.includes('MEDICAL') || s.includes('RESCUE')) return 'CDRRMO';
  return s;
}

// Synchronize per-department status & compute consolidated incident status
async function syncIncidentDepartmentStatus(reqId, actingDept, newStatus) {
  const [incRows] = await db.query('SELECT incType, reqStatus FROM emergency_request WHERE Req_ID = ?', [reqId]);
  if (incRows.length === 0) return { consolidatedStatus: 'Pending', deptStatuses: [] };

  const incType = incRows[0].incType;
  const involvedDepts = getInvolvedDepartments(incType);
  const normalizedActing = normalizeDepartmentName(actingDept);

  // 1. Ensure rows exist in incident_department_status for each involved department
  for (const dept of involvedDepts) {
    await db.query(
      'INSERT IGNORE INTO incident_department_status (req_ID, dept_name, status) VALUES (?, ?, "Pending")',
      [reqId, dept]
    );
  }

  // 2. Update department status for acting department
  let targetDepts = [];
  if (normalizedActing !== 'ALL' && involvedDepts.includes(normalizedActing)) {
    targetDepts = [normalizedActing];
  } else {
    // If actingDept is ALL or unspecified/superadmin, target the first involved department that is still 'Pending'
    const [pendingRows] = await db.query(
      'SELECT dept_name FROM incident_department_status WHERE req_ID = ? AND LOWER(status) = "pending" LIMIT 1',
      [reqId]
    );
    if (pendingRows.length > 0) {
      targetDepts = [pendingRows[0].dept_name];
    } else if (involvedDepts.length > 0) {
      targetDepts = [involvedDepts[0]];
    }
  }

  for (const tDept of targetDepts) {
    await db.query(
      'UPDATE incident_department_status SET status = ? WHERE req_ID = ? AND dept_name = ?',
      [newStatus, reqId, tDept]
    );
  }

  // 3. Fetch all department statuses for this incident
  const [deptRows] = await db.query(
    'SELECT dept_name, status FROM incident_department_status WHERE req_ID = ?',
    [reqId]
  );

  // 4. Rule: Must have response (acceptance, dispatch, or cancellation) from ALL involved departments before updating overall status
  const allResponded = deptRows.length > 0 && deptRows.every(r => r.status.toLowerCase() !== 'pending');

  let consolidatedStatus = 'Pending';
  if (allResponded) {
    const statuses = deptRows.map(r => r.status.toLowerCase());
    const isAllCancelled = statuses.every(s => s === 'cancelled' || s === 'declined');

    if (isAllCancelled) {
      consolidatedStatus = 'Declined';
    } else {
      const activeDepts = deptRows.filter(r => r.status.toLowerCase() !== 'cancelled' && r.status.toLowerCase() !== 'declined');
      const activeStatuses = activeDepts.map(r => r.status.toLowerCase());

      const isAllCompleted = activeStatuses.length > 0 && activeStatuses.every(s => s === 'completed');
      const isAllEnRoute = activeStatuses.length > 0 && activeStatuses.every(s => s === 'en route' || s === 'dispatched' || s === 'en_route' || s === 'completed');

      if (isAllCompleted) {
        consolidatedStatus = 'Completed';
      } else if (isAllEnRoute) {
        consolidatedStatus = 'En Route';
      } else {
        consolidatedStatus = 'Accepted';
      }
    }
  } else {
    // If not all departments have responded yet, overall status remains Pending
    consolidatedStatus = 'Pending';
  }

  // 5. Update emergency_request.reqStatus
  await db.query('UPDATE emergency_request SET reqStatus = ? WHERE Req_ID = ?', [consolidatedStatus, reqId]);

  return { consolidatedStatus, deptStatuses: deptRows, allResponded };
}

// Register a device as trusted after successful MFA verification
app.post('/api/trust-device', async (req, res) => {
  const { userId, deviceToken, deviceLabel } = req.body;
  if (!userId || !deviceToken) {
    return res.status(400).json({ success: false, error: 'userId and deviceToken are required' });
  }
  try {
    const tokenHash = crypto.createHash('sha256').update(String(deviceToken)).digest('hex');
    const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000); // 30 days
    await db.query(`
      INSERT INTO trusted_devices (user_ID, device_token_hash, device_label, expires_at)
      VALUES (?, ?, ?, ?)
      ON DUPLICATE KEY UPDATE last_used_at = NOW(), expires_at = VALUES(expires_at)
    `, [Number(userId), tokenHash, deviceLabel || 'Unknown Device', expiresAt]);
    console.log('[TrustedDevice] Device registered for user ' + userId);
    res.json({ success: true });
  } catch (err) {
    console.error('[trust-device] Error:', err.message);
    res.status(500).json({ success: false, error: err.message });
  }
});

// Check if a device token is trusted and return user info (bypasses MFA)
app.post('/api/check-trusted-device', async (req, res) => {
  const { userId, deviceToken } = req.body;
  if (!userId || !deviceToken) {
    return res.json({ success: true, trusted: false });
  }
  try {
    const tokenHash = crypto.createHash('sha256').update(String(deviceToken)).digest('hex');
    const [rows] = await db.query(`
      SELECT td.id, td.expires_at
      FROM trusted_devices td
      WHERE td.user_ID = ? AND td.device_token_hash = ? AND td.expires_at > NOW()
    `, [Number(userId), tokenHash]);

    if (rows.length === 0) return res.json({ success: true, trusted: false });

    await db.query('UPDATE trusted_devices SET last_used_at = NOW() WHERE id = ?', [rows[0].id]);

    const [users] = await db.query(
      'SELECT r.Citizen_ID, r.userName, r.email, r.role, r.deptID, d.deptName as department FROM resident r LEFT JOIN department d ON r.deptID = d.dept_ID WHERE r.Citizen_ID = ?',
      [Number(userId)]
    );
    if (users.length === 0) return res.json({ success: true, trusted: false });
    const u = users[0];

    await logSystemEvent({
      userId: u.Citizen_ID, role: u.role, action: 'LOGIN_TRUSTED_DEVICE',
      entityType: 'USER', entityId: u.Citizen_ID, ip: req.ip, status: 'SUCCESS',
      details: { email: u.email, mfa: 'skipped_trusted_device' }
    });

    return res.json({
      success: true, trusted: true,
      user: { id: u.Citizen_ID, fullName: u.userName, email: u.email, role: u.role, deptID: u.deptID, department: u.department || '' }
    });
  } catch (err) {
    console.error('[check-trusted-device] Error:', err.message);
    res.status(500).json({ success: false, trusted: false, error: err.message });
  }
});

// Revoke all trusted devices for a user (on logout or security reset)
app.delete('/api/trust-device/:userId', async (req, res) => {
  const userId = req.params.userId;
  try {
    await db.query('DELETE FROM trusted_devices WHERE user_ID = ?', [Number(userId)]);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// GET single emergency request details
app.get('/api/emergency-requests/:id', async (req, res) => {
  try {
    const [rows] = await db.query(
      'SELECT Req_ID, Citizen_ID, incType, latitude, longitude, reqStatus, description, image_path, SOS_timeStamp FROM emergency_request WHERE Req_ID = ?',
      [req.params.id]
    );
    if (rows.length === 0) {
      return res.status(404).json({ success: false, message: 'Emergency request not found' });
    }
    const incident = rows[0];

    const [deptRows] = await db.query(
      'SELECT dept_name, status FROM incident_department_status WHERE req_ID = ?',
      [incident.Req_ID]
    );
    if (deptRows.length === 0) {
      const involved = getInvolvedDepartments(incident.incType);
      incident.department_statuses = involved.map(d => ({ dept_name: d, status: incident.reqStatus || 'Pending' }));
    } else {
      incident.department_statuses = deptRows;
    }

    res.json({ success: true, data: incident });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// GET all emergency requests for a specific citizen
app.get('/api/citizen-emergency-requests/:citizenId', async (req, res) => {
  try {
    const [rows] = await db.query(
      'SELECT Req_ID, Citizen_ID, incType, latitude, longitude, reqStatus, description, image_path, SOS_timeStamp FROM emergency_request WHERE Citizen_ID = ? ORDER BY Req_ID DESC',
      [req.params.citizenId]
    );
    for (const incident of rows) {
      const [deptRows] = await db.query(
        'SELECT dept_name, status FROM incident_department_status WHERE req_ID = ?',
        [incident.Req_ID]
      );
      if (deptRows.length === 0) {
        const involved = getInvolvedDepartments(incident.incType);
        incident.department_statuses = involved.map(d => ({ dept_name: d, status: incident.reqStatus || 'Pending' }));
      } else {
        incident.department_statuses = deptRows;
      }
    }
    res.json({ success: true, data: rows });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Authentication Endpoints
app.post('/api/login', async (req, res) => {
  const { email, password } = req.body;
  try {
    const [rows] = await db.query(
      'SELECT r.Citizen_ID, r.userName, r.email, r.role, r.pass_hash, r.deptID, d.deptName as department FROM resident r LEFT JOIN department d ON r.deptID = d.dept_ID WHERE r.email = ?',
      [email]
    );

    if (rows.length === 0) {
      return res.status(401).json({ success: false, error: 'Invalid credentials' });
    }

    const user = rows[0];
    const passwordMatch = await bcrypt.compare(password, user.pass_hash);

    if (!passwordMatch) {
      return res.status(401).json({ success: false, error: 'Invalid credentials' });
    }

    // Check if MFA is enabled in user_settings table
    const [settings] = await db.query(
      'SELECT mfa_enabled FROM user_settings WHERE user_ID = ?',
      [user.Citizen_ID]
    );

    const mfaEnabled = settings.length > 0 ? (settings[0].mfa_enabled === 1 || settings[0].mfa_enabled === true) : true;

    if (mfaEnabled) {
      // Generate 6-digit OTP code (random 6-digit number)
      const otpCode = Math.floor(100000 + Math.random() * 900000).toString();
      activeMfaStore.set(Number(user.Citizen_ID), {
        code: otpCode,
        expiresAt: Date.now() + 5 * 60 * 1000,
        user: {
          id: user.Citizen_ID,
          fullName: user.userName,
          email: user.email,
          role: user.role,
          deptID: user.deptID,
          department: user.department || ''
        }
      });

      console.log(`\n======================================================`);
      console.log(`[MFA OTP CODE FOR TESTING]`);
      console.log(`User: ${user.email} (ID: ${user.Citizen_ID})`);
      console.log(`6-Digit Verification Code: [ ${otpCode} ]`);
      console.log(`======================================================\n`);

      // Dispatch email attempt
      sendMfaEmail(user.email, otpCode, user.userName);

      const parts = user.email.split('@');
      const maskedUser = parts[0].length > 2 
        ? parts[0][0] + '*'.repeat(parts[0].length - 2) + parts[0][parts[0].length - 1]
        : parts[0][0] + '*';
      const maskedEmail = `${maskedUser}@${parts[1] || 'email.com'}`;

      return res.json({
        success: true,
        mfaRequired: true,
        userId: user.Citizen_ID,
        targetEmail: user.email,
        maskedEmail: maskedEmail,
        otpCode: otpCode,
        message: `MFA verification code sent to ${maskedEmail}`
      });
    }

    // Direct login if MFA is disabled
    await logSystemEvent({
      userId: user.Citizen_ID,
      role: user.role,
      action: 'LOGIN',
      entityType: 'USER',
      entityId: user.Citizen_ID,
      ip: req.ip,
      status: 'SUCCESS',
      details: { email: user.email, mfa: false }
    });

    res.json({
      success: true,
      mfaRequired: false,
      user: {
        id: user.Citizen_ID,
        fullName: user.userName,
        email: user.email,
        role: user.role,
        deptID: user.deptID,
        department: user.department || ''
      }
    });
  } catch (err) {
    console.error('Login error:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

// Verify MFA OTP Code Endpoint
app.post('/api/verify-mfa', async (req, res) => {
  const { userId, otpCode } = req.body;
  try {
    const record = activeMfaStore.get(Number(userId));

    if (!record || record.expiresAt < Date.now()) {
      return res.status(400).json({ success: false, error: 'Verification code expired or invalid' });
    }

    if (record.code !== otpCode.toString().trim()) {
      return res.status(400).json({ success: false, error: 'Incorrect 6-digit verification code' });
    }

    // Clear used code
    activeMfaStore.delete(Number(userId));

    await logSystemEvent({
      userId: record.user.id,
      role: record.user.role,
      action: 'LOGIN_MFA_VERIFIED',
      entityType: 'USER',
      entityId: record.user.id,
      ip: req.ip,
      status: 'SUCCESS',
      details: { email: record.user.email, mfa: true }
    });

    res.json({
      success: true,
      user: record.user
    });
  } catch (err) {
    console.error('MFA verification error:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

app.post('/api/register', async (req, res) => {
  const { fullName, contactNo, email, password, fcmToken } = req.body;
  try {
    // Check if user already exists
    const [existing] = await db.query('SELECT Citizen_ID FROM resident WHERE email = ?', [email]);
    if (existing.length > 0) {
      return res.status(400).json({ success: false, error: 'User already exists' });
    }

    // Hash password
    const hashedPassword = await bcrypt.hash(password, 10);

    // Insert new user
    const [result] = await db.query(
      'INSERT INTO resident (userName, contactNo, email, pass_hash, role, fcm_token) VALUES (?, ?, ?, ?, "Citizen", ?)',
      [fullName, contactNo, email, hashedPassword, fcmToken || null]
    );

    const userId = result.insertId;

    // Log registration
    await logSystemEvent({
      userId: userId,
      role: 'Citizen',
      action: 'REGISTER',
      entityType: 'USER',
      entityId: userId,
      ip: req.ip,
      status: 'SUCCESS',
      details: { email: email }
    });

    res.json({ success: true, userId: userId });
  } catch (err) {
    console.error('Registration error:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

// Accounts Management
app.get('/api/admin/accounts', async (req, res) => {
  try {
    const [rows] = await db.query(`
      SELECT 
        r.Citizen_ID as id,
        r.Citizen_ID,
        r.userName as name,
        r.userName,
        r.email,
        r.contactNo as phone,
        r.contactNo,
        r.role,
        r.deptID,
        COALESCE(d.deptName, 'Unassigned') as agency,
        'Active' as status,
        '#10B981' as statusColor,
        CASE 
          WHEN d.deptName = 'PNP' THEN '#2563EB'
          WHEN d.deptName = 'BFP' THEN '#FF6B00'
          WHEN d.deptName = 'CDRRMO' THEN '#10B981'
          ELSE '#64748B'
        END as agencyBg,
        CASE 
          WHEN r.role = 'Superadmin' THEN '#7C3AED'
          WHEN r.role = 'Admin' THEN '#2563EB'
          ELSE '#0D9488'
        END as avatarBg,
        CASE 
          WHEN r.role = 'Superadmin' THEN '#F3E8FF'
          WHEN r.role = 'Admin' THEN '#EFF6FF'
          ELSE '#F0FDFA'
        END as roleBg,
        CASE 
          WHEN r.role = 'Superadmin' THEN '#6B21A8'
          WHEN r.role = 'Admin' THEN '#1D4ED8'
          ELSE '#0F766E'
        END as roleText,
        UPPER(SUBSTRING(r.userName, 1, 2)) as initials,
        'Just now' as lastActive,
        'Active' as created
      FROM resident r 
      LEFT JOIN department d ON r.deptID = d.dept_ID
      ORDER BY r.userName
    `);
    res.json({ success: true, data: rows });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

app.post('/api/admin/accounts', async (req, res) => {
  const { fullName, userName, contactNo, phone, email, password, role, deptID } = req.body;
  const nameToSave = fullName || userName;
  const phoneToSave = contactNo || phone;
  
  if (!nameToSave || !email || !password) {
    return res.status(400).json({ success: false, error: 'Name, email and password are required' });
  }

  try {
    const hashedPassword = await bcrypt.hash(password, 10);
    const [result] = await db.query(
      'INSERT INTO resident (userName, contactNo, email, pass_hash, role, deptID) VALUES (?, ?, ?, ?, ?, ?)',
      [nameToSave, phoneToSave || '', email, hashedPassword, role || 'Citizen', deptID || null]
    );

    io.emit('refreshManagementData');
    res.json({ success: true, userId: result.insertId });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

app.put('/api/admin/accounts/:accountId', async (req, res) => {
  const accountId = req.params.accountId;
  const { fullName, userName, contactNo, phone, email, role, deptID } = req.body;
  const nameToSave = fullName || userName;
  const phoneToSave = contactNo || phone;

  try {
    await db.query(
      'UPDATE resident SET userName = COALESCE(?, userName), contactNo = COALESCE(?, contactNo), email = COALESCE(?, email), role = COALESCE(?, role), deptID = ? WHERE Citizen_ID = ?',
      [nameToSave || null, phoneToSave || null, email || null, role || null, deptID || null, accountId]
    );

    io.emit('refreshManagementData');
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

app.delete('/api/admin/accounts/:accountId', async (req, res) => {
  const accountId = req.params.accountId;
  try {
    await db.query('DELETE FROM resident WHERE Citizen_ID = ?', [accountId]);
    io.emit('refreshManagementData');
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Vehicles Management
app.get('/api/admin/vehicles-manage', async (req, res) => {
  try {
    const [rows] = await db.query(`
      SELECT v.*,
             COALESCE(v.plate_no, CONCAT('Unit #', v.vehicle_ID)) AS plate_no,
             COALESCE(v.vehicle_type, 'Unassigned Type') AS vehicle_type,
             COALESCE(d.deptName, 'Unassigned') AS deptName,
             l.latitude, l.longitude, l.speed_kph, l.course_deg,
             l.altitude_m, l.satellites, l.fix_timestamp, l.source
      FROM response_vehicle v 
      LEFT JOIN department d ON v.dept_ID = d.dept_ID
      LEFT JOIN vehicle_location l ON v.vehicle_ID = l.vehicle_ID
      ORDER BY v.vehicle_ID
    `);
    res.json({ success: true, data: rows });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Create Vehicle
app.post('/api/admin/vehicles', async (req, res) => {
  const { plate_no, vehicle_type, dept_ID, deptName, status } = req.body;
  try {
    let targetDeptId = dept_ID || null;
    if (!targetDeptId && deptName && deptName !== 'Unassigned') {
      const [depts] = await db.query('SELECT dept_ID FROM department WHERE deptName = ? LIMIT 1', [deptName]);
      if (depts.length > 0) targetDeptId = depts[0].dept_ID;
    }
    const [result] = await db.query(
      'INSERT INTO response_vehicle (plate_no, vehicle_type, dept_ID, status) VALUES (?, ?, ?, ?)',
      [plate_no || null, vehicle_type || null, targetDeptId, status || 'Available']
    );
    io.emit('refreshManagementData', { type: 'vehicle_created' });
    io.emit('vehicleUpdate', {});
    res.json({ success: true, message: 'Vehicle created successfully', vehicle_ID: result.insertId });
  } catch (err) { res.status(500).json({ success: false, error: err.message }); }
});

// Update Vehicle
app.put('/api/admin/vehicles/:vehicleId', async (req, res) => {
  const vehicleId = req.params.vehicleId;
  const { plate_no, vehicle_type, dept_ID, deptName, status } = req.body;
  try {
    let targetDeptId = dept_ID || null;
    if (!targetDeptId && deptName && deptName !== 'Unassigned') {
      const [depts] = await db.query('SELECT dept_ID FROM department WHERE deptName = ? LIMIT 1', [deptName]);
      if (depts.length > 0) targetDeptId = depts[0].dept_ID;
    }
    await db.query(
      'UPDATE response_vehicle SET plate_no = ?, vehicle_type = ?, dept_ID = ?, status = ? WHERE vehicle_ID = ?',
      [plate_no || null, vehicle_type || null, targetDeptId, status || 'Available', vehicleId]
    );
    io.emit('refreshManagementData', { type: 'vehicle_updated' });
    io.emit('vehicleUpdate', {});
    res.json({ success: true, message: 'Vehicle updated successfully' });
  } catch (err) { res.status(500).json({ success: false, error: err.message }); }
});

// Delete Vehicle (Resets vehicle to unassigned state)
app.delete('/api/admin/vehicles/:vehicleId', async (req, res) => {
  const vehicleId = req.params.vehicleId;
  try {
    const defaultPlate = generateUnassignedPlate();
    await db.query(
      `UPDATE response_vehicle 
       SET dept_ID = NULL, 
           plate_no = ?, 
           vehicle_type = 'Unassigned', 
           status = 'Available' 
       WHERE vehicle_ID = ?`,
      [defaultPlate, vehicleId]
    );
    io.emit('refreshManagementData', { type: 'vehicle_deleted' });
    io.emit('vehicleUpdate', {});
    res.json({ success: true, message: 'Vehicle returned to unassigned fleet' });
  } catch (err) { res.status(500).json({ success: false, error: err.message }); }
});

// Departments
app.get('/api/admin/departments', async (req, res) => {
  try {
    const [rows] = await db.query('SELECT * FROM department ORDER BY deptName');
    res.json({ success: true, data: rows });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

app.put('/api/admin/departments/:deptId', async (req, res) => {
  const deptId = req.params.deptId;
  const { deptName, deptLocation, contactInfo } = req.body;
  try {
    await db.query(
      'UPDATE department SET deptName = ?, deptLocation = ?, contactInfo = ? WHERE dept_ID = ?',
      [deptName, deptLocation, contactInfo, deptId]
    );
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Update Dispatch Status
app.put('/api/admin/dispatch/:dispId/status', async (req, res) => {
  const dispId = req.params.dispId;
  const { status } = req.body;
  try {
    await db.query('UPDATE dispatch_event SET status = ? WHERE Disp_ID = ?', [status, dispId]);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Update FCM Token
app.put('/api/user/:userId/fcm-token', async (req, res) => {
  const userId = req.params.userId;
  const { fcmToken } = req.body;
  try {
    await db.query('UPDATE resident SET fcm_token = ? WHERE Citizen_ID = ?', [fcmToken, userId]);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// NOTE: Notification API endpoints are defined below in the dedicated
// "NOTIFICATIONS API ENDPOINTS" section to avoid route shadowing.

// Media Gallery - Evidence photos from emergency requests
app.get('/api/admin/media-gallery', async (req, res) => {
  try {
    const [rows] = await db.query(`
      SELECT 
        e.Req_ID,
        CONCAT('INC-', e.Req_ID) as incidentId,
        e.incType as category,
        e.description,
        e.latitude,
        e.longitude,
        COALESCE(r.userName, 'Citizen Reporter') as reporterName,
        e.image_path,
        e.image_path as file_path,
        e.image_path as imagePath,
        SUBSTRING_INDEX(e.image_path, '/', -1) as filename,
        e.SOS_timeStamp as uploadedAt,
        e.SOS_timeStamp as uploaded_at
      FROM emergency_request e
      LEFT JOIN resident r ON e.Citizen_ID = r.Citizen_ID
      WHERE e.image_path IS NOT NULL AND e.image_path != ''
      ORDER BY e.SOS_timeStamp DESC
    `);

    // Add tags array and formatted properties expected by MediaScreen and Dashboard
    const formatted = rows.map(r => {
      const ext = (r.filename && r.filename.includes('.')) ? r.filename.split('.').pop().toUpperCase() : 'JPG';
      let timeStr = '--:--';
      if (r.uploadedAt) {
        const d = new Date(r.uploadedAt);
        if (!isNaN(d.getTime())) {
          timeStr = d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
        }
      }
      
      let categoryColor = '#64748B';
      let bgColor = '#F1F5F9';
      const cat = (r.category || '').toLowerCase();
      if (cat.includes('fire')) {
        categoryColor = '#EA580C';
        bgColor = '#FFEDD5';
      } else if (cat.includes('medical')) {
        categoryColor = '#DC2626';
        bgColor = '#FEE2E2';
      } else if (cat.includes('police')) {
        categoryColor = '#2563EB';
        bgColor = '#DBEAFE';
      } else if (cat.includes('rescue') || cat.includes('flood') || cat.includes('cdrrmo')) {
        categoryColor = '#059669';
        bgColor = '#D1FAE5';
      }

      const locationStr = (r.latitude && r.longitude)
        ? `Iriga City (${parseFloat(r.latitude).toFixed(4)}, ${parseFloat(r.longitude).toFixed(4)})`
        : 'Iriga City';

      return {
        ...r,
        incidentId: r.incidentId || `INC-${r.Req_ID}`,
        imagePath: r.image_path || '',
        filename: r.filename || `incident_${r.Req_ID}.jpg`,
        ext: ext,
        size: '1.2 MB',
        time: timeStr,
        category: r.category || 'General',
        categoryColor: categoryColor,
        bgColor: bgColor,
        location: locationStr,
        reporterName: r.reporterName || 'Citizen Reporter',
        tags: [r.category || 'General', r.incidentId || `INC-${r.Req_ID}`]
      };
    });

    res.json({ success: true, data: formatted });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Media Filters
app.get('/api/admin/media-filters', async (req, res) => {
  try {
    const [counts] = await db.query(`
      SELECT incType, COUNT(*) as count
      FROM emergency_request
      WHERE image_path IS NOT NULL AND image_path != ''
      GROUP BY incType
    `);
    
    const [total] = await db.query(`
      SELECT COUNT(*) as count
      FROM emergency_request
      WHERE image_path IS NOT NULL AND image_path != ''
    `);

    const totalCount = total.length > 0 ? total[0].count : 0;
    const filters = [
      { label: 'All Incidents', count: totalCount, color: null },
      ...counts.map(c => {
        let color = '#64748B';
        const cat = (c.incType || '').toLowerCase();
        if (cat.includes('fire')) color = '#EA580C';
        else if (cat.includes('medical')) color = '#DC2626';
        else if (cat.includes('police')) color = '#2563EB';
        else if (cat.includes('rescue') || cat.includes('flood') || cat.includes('cdrrmo')) color = '#059669';
        
        return {
          label: c.incType || 'General',
          count: c.count,
          color: color
        };
      })
    ];

    res.json({ success: true, data: filters });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// System Logs
app.get('/api/admin/system-logs', async (req, res) => {
  try {
    const { userId, action, entityType, limit = 100, startDate, endDate } = req.query;
    let query = `
      SELECT sl.*, r.userName as userName, r.role as userRole
      FROM system_logs sl
      LEFT JOIN resident r ON sl.user_ID = r.Citizen_ID
      WHERE 1=1
    `;
    const params = [];

    if (userId) {
      query += ' AND sl.user_ID = ?';
      params.push(userId);
    }
    if (action) {
      query += ' AND sl.action = ?';
      params.push(action);
    }
    if (entityType) {
      query += ' AND sl.entity_type = ?';
      params.push(entityType);
    }
    if (startDate) {
      query += ' AND sl.timestamp >= ?';
      params.push(startDate);
    }
    if (endDate) {
      query += ' AND sl.timestamp <= ?';
      params.push(endDate);
    }

    query += ' ORDER BY sl.timestamp DESC LIMIT ?';
    params.push(parseInt(limit));

    const [rows] = await db.query(query, params);
    res.json({ success: true, data: rows });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

app.post('/api/admin/system-logs', async (req, res) => {
  const { userId, action, entityType, entityId, details, ipAddress } = req.body;
  try {
    const [result] = await db.query(
      'INSERT INTO system_logs (user_ID, action, entity_type, entity_id, details, ip_address, user_role) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [userId, action, entityType, entityId, details, ipAddress, 'SYSTEM']
    );
    res.json({ success: true, logId: result.insertId });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// System Log Statistics
app.get('/api/admin/system-logs/stats', async (req, res) => {
  try {
    const [actionStats] = await db.query(`
      SELECT action, entity_type, COUNT(*) as count
      FROM system_logs
      GROUP BY action, entity_type
      ORDER BY count DESC
    `);

    const [timeStats] = await db.query(`
      SELECT
        DATE(timestamp) as date,
        COUNT(*) as count
      FROM system_logs
      WHERE timestamp >= DATE_SUB(NOW(), INTERVAL 7 DAY)
      GROUP BY DATE(timestamp)
      ORDER BY date DESC
    `);

    const [userStats] = await db.query(`
      SELECT 
        sl.user_ID,
        r.userName,
        r.role,
        COUNT(*) as count
      FROM system_logs sl
      LEFT JOIN resident r ON sl.user_ID = r.Citizen_ID
      GROUP BY sl.user_ID, r.userName, r.role
      ORDER BY count DESC
      LIMIT 10
    `);

    res.json({
      success: true,
      data: {
        actionStats,
        timeStats,
        userStats
      }
    });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// System Log Summary
app.get('/api/admin/system-logs/summary', async (req, res) => {
  try {
    const [totalLogs] = await db.query('SELECT COUNT(*) as count FROM system_logs');
    const [todayLogs] = await db.query('SELECT COUNT(*) as count FROM system_logs WHERE DATE(timestamp) = CURDATE()');
    const [weekLogs] = await db.query('SELECT COUNT(*) as count FROM system_logs WHERE timestamp >= DATE_SUB(NOW(), INTERVAL 7 DAY)');
    
    const [topActions] = await db.query(`
      SELECT action, COUNT(*) as count
      FROM system_logs
      GROUP BY action
      ORDER BY count DESC
      LIMIT 5
    `);

    const [topEntities] = await db.query(`
      SELECT entity_type, COUNT(*) as count
      FROM system_logs
      GROUP BY entity_type
      ORDER BY count DESC
      LIMIT 5
    `);

    res.json({
      success: true,
      data: {
        totalLogs: totalLogs[0].count,
        todayLogs: todayLogs[0].count,
        weekLogs: weekLogs[0].count,
        topActions,
        topEntities
      }
    });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Export System Logs as CSV
app.get('/api/admin/system-logs/export', async (req, res) => {
  try {
    const { startDate, endDate, entityType, action } = req.query;
    
    let query = `
      SELECT
        sl.log_id,
        sl.user_ID,
        r.userName as user_name,
        r.role as user_role,
        sl.action,
        sl.entity_type,
        sl.entity_id,
        sl.details,
        sl.ip_address,
        sl.timestamp
      FROM system_logs sl
      LEFT JOIN resident r ON sl.user_ID = r.Citizen_ID
      WHERE 1=1
    `;
    const params = [];

    if (startDate) {
      query += ' AND sl.timestamp >= ?';
      params.push(startDate);
    }
    if (endDate) {
      query += ' AND sl.timestamp <= ?';
      params.push(endDate);
    }
    if (entityType) {
      query += ' AND sl.entity_type = ?';
      params.push(entityType);
    }
    if (action) {
      query += ' AND sl.action = ?';
      params.push(action);
    }

    query += ' ORDER BY sl.timestamp DESC';

    const [rows] = await db.query(query, params);

    // Convert to CSV
    const headers = ['Log ID', 'User ID', 'User Name', 'User Role', 'Action', 'Entity Type', 'Entity ID', 'Details', 'IP Address', 'Timestamp'];
    const csvRows = [headers.join(',')];

    rows.forEach(row => {
      const values = [
        row.log_id,
        row.user_ID || '',
        row.user_name || '',
        row.user_role || '',
        row.action,
        row.entity_type,
        row.entity_id || '',
        `"${(row.details || '').replace(/"/g, '""')}"`, // Escape quotes in details
        row.ip_address || '',
        row.timestamp
      ];
      csvRows.push(values.join(','));
    });

    const csv = csvRows.join('\n');
    
    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', 'attachment; filename=system_logs_export.csv');
    res.send(csv);
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// 3. Admin Dispatch Execution
app.post('/api/admin/dispatch', async (req, res) => {
  const { emergency_id, vehicle_id, admin_id, reqId, vehicleId, department } = req.body;
  // Support both parameter naming conventions
  const finalEmergencyId = emergency_id || reqId;
  const finalVehicleId = vehicle_id || vehicleId;
  const finalAdminId = admin_id || 13;
  
  try {
    const [result] = await db.query(
      'INSERT INTO dispatch_event (Req_ID, vehicle_ID, Admin_ID, status, Dispatch_timeStamp) VALUES (?, ?, ?, "En Route", NOW())',
      [finalEmergencyId, finalVehicleId, finalAdminId]
    );

    const dispatchId = result.insertId;

    // Synchronize statuses
    await db.query("UPDATE response_vehicle SET status = 'En Route' WHERE vehicle_ID = ?", [finalVehicleId]);
    let actingDept = department;
    if (!actingDept || actingDept === 'ALL') {
      const [vDepts] = await db.query(
        'SELECT d.deptName FROM response_vehicle v LEFT JOIN department d ON v.dept_ID = d.dept_ID WHERE v.vehicle_ID = ?',
        [finalVehicleId]
      );
      if (vDepts.length > 0 && vDepts[0].deptName) {
        actingDept = vDepts[0].deptName;
      }
    }
    await syncIncidentDepartmentStatus(finalEmergencyId, actingDept || 'ALL', 'En Route');

    await logSystemEvent({
      userId: finalAdminId,
      role: 'ADMIN',
      action: 'UNIT_DISPATCHED',
      entityType: 'dispatch_event',
      entityId: dispatchId,
      ip: req.ip,
      status: 'SUCCESS',
      details: { emergency_id: finalEmergencyId, vehicle_id: finalVehicleId }
    });

    // Create notification for dispatch
    try {
      const [admins] = await db.query("SELECT Citizen_ID FROM resident WHERE role IN ('Admin', 'Superadmin')");
      const [vehicleRows] = await db.query("SELECT plate_no, vehicle_type FROM response_vehicle WHERE vehicle_ID = ?", [finalVehicleId]);
      const vInfo = vehicleRows.length > 0 ? `${vehicleRows[0].vehicle_type} (${vehicleRows[0].plate_no})` : `Vehicle #${finalVehicleId}`;
      for (const admin of admins) {
        await db.query(
          'INSERT INTO notifications (recipient_ID, title, message, notification_type, req_ID, disp_ID, is_read, timestamp) VALUES (?, ?, ?, ?, ?, ?, 0, NOW())',
          [admin.Citizen_ID, 'Unit Dispatched', `${vInfo} dispatched to Incident #${finalEmergencyId}.`, 'DISPATCH', finalEmergencyId, dispatchId]
        );
      }
      io.emit('newNotification', { type: 'DISPATCH', emergencyId: finalEmergencyId, dispatchId });
    } catch (notifErr) {
      console.error('Error creating dispatch notification:', notifErr);
    }

    io.emit('refreshIncidentQueueEvent');
    io.emit('refreshManagementData');
    res.json({ success: true, dispatch_id: dispatchId });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// ==========================================
// NOTIFICATIONS API ENDPOINTS
// ==========================================

// Get Notifications for User
app.get('/api/notifications/:userId', async (req, res) => {
  const userId = req.params.userId;
  try {
    const [rows] = await db.query(
      `SELECT * FROM notifications 
       WHERE recipient_ID = ? OR recipient_ID IS NULL 
       ORDER BY timestamp DESC LIMIT 50`,
      [userId]
    );
    res.json({ success: true, data: rows });
  } catch (err) {
    console.error('Fetch notifications error:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

// Add Notification
app.post('/api/notifications', async (req, res) => {
  const { recipientId, title, message, reqId, dispId, type } = req.body;
  try {
    const notifTitle = title || 'System Alert';
    const notifType = type || 'SYSTEM';
    const [result] = await db.query(
      'INSERT INTO notifications (recipient_ID, title, message, notification_type, req_ID, disp_ID, is_read, timestamp) VALUES (?, ?, ?, ?, ?, ?, 0, NOW())',
      [recipientId || null, notifTitle, message, notifType, reqId || null, dispId || null]
    );

    io.emit('newNotification', {
      notificationId: result.insertId,
      recipientId,
      title: notifTitle,
      message,
      type: notifType
    });

    res.json({ success: true, notificationId: result.insertId });
  } catch (err) {
    console.error('Add notification error:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

// Mark Single Notification as Read
app.put('/api/notifications/:id/read', async (req, res) => {
  const notifId = req.params.id;
  try {
    await db.query(
      'UPDATE notifications SET is_read = 1, read_at = NOW() WHERE notification_ID = ?',
      [notifId]
    );
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Mark All Notifications as Read for User
app.put('/api/notifications/:userId/read-all', async (req, res) => {
  const userId = req.params.userId;
  try {
    await db.query(
      'UPDATE notifications SET is_read = 1, read_at = NOW() WHERE recipient_ID = ? OR recipient_ID IS NULL',
      [userId]
    );
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Get Unread Notification Count
app.get('/api/notifications/:userId/unread-count', async (req, res) => {
  const userId = req.params.userId;
  try {
    const [rows] = await db.query(
      'SELECT COUNT(*) as count FROM notifications WHERE (recipient_ID = ? OR recipient_ID IS NULL) AND is_read = 0',
      [userId]
    );
    res.json({ success: true, count: rows[0].count });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// Change User Password
app.post('/api/user/:userId/change-password', async (req, res) => {
  try {
    const userId = req.params.userId;
    const { currentPassword, newPassword } = req.body;

    const [rows] = await db.query('SELECT pass_hash FROM resident WHERE Citizen_ID = ?', [userId]);
    if (rows.length === 0) {
      return res.status(404).json({ success: false, error: 'User not found' });
    }

    const match = await bcrypt.compare(currentPassword, rows[0].pass_hash);
    if (!match) {
      return res.status(400).json({ success: false, error: 'Current password does not match' });
    }

    const newHash = await bcrypt.hash(newPassword, 10);
    await db.query('UPDATE resident SET pass_hash = ? WHERE Citizen_ID = ?', [newHash, userId]);

    await logSystemEvent({
      userId: parseInt(userId),
      action: 'PASSWORD_CHANGED',
      entityType: 'USER',
      entityId: parseInt(userId),
      status: 'SUCCESS'
    });

    res.json({ success: true, message: 'Password updated successfully' });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

server.listen(3000, '0.0.0.0', () => console.log('Audit Engine & API Server running on port 3000 (bound to 0.0.0.0)'));


