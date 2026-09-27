const mysql = require('mysql2/promise');

async function testLogs() {
  const db = mysql.createPool({
    host: 'localhost',
    user: 'root',
    password: '',
    database: 'resq_db',
    waitForConnections: true,
    connectionLimit: 10,
    queueLimit: 0
  });

  try {
    console.log('Adding test log entries...');
    
    const testLogs = [
      {
        user_ID: 13,
        user_role: 'Superadmin',
        action: 'LOGIN',
        entity_type: 'USER',
        entity_id: 13,
        status: 'SUCCESS',
        details: 'Superadmin login from 192.168.1.100',
        ip_address: '192.168.1.100'
      },
      {
        user_ID: 16,
        user_role: 'Admin',
        action: 'CREATE',
        entity_type: 'INCIDENT',
        entity_id: 1,
        status: 'SUCCESS',
        details: 'Created new emergency request #1',
        ip_address: '192.168.1.101'
      },
      {
        user_ID: 16,
        user_role: 'Admin',
        action: 'DISPATCH',
        entity_type: 'DISPATCH',
        entity_id: 1,
        status: 'SUCCESS',
        details: 'Dispatched vehicle to incident #1',
        ip_address: '192.168.1.101'
      },
      {
        user_ID: null,
        user_role: 'SYSTEM',
        action: 'STATUS_CHANGE',
        entity_type: 'INCIDENT',
        entity_id: 1,
        status: 'SUCCESS',
        details: 'Incident status changed to IN_PROGRESS',
        ip_address: null
      }
    ];

    for (const log of testLogs) {
      await db.query(
        'INSERT INTO system_logs (user_ID, user_role, action, entity_type, entity_id, status, details, ip_address) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [log.user_ID, log.user_role, log.action, log.entity_type, log.entity_id, log.status, log.details, log.ip_address]
      );
      console.log(`Added log: ${log.action} on ${log.entity_type}`);
    }

    console.log('Test logs added successfully!');
  } catch (err) {
    console.error('Error adding test logs:', err.message);
  } finally {
    await db.end();
  }
}

testLogs();