const mysql = require('mysql2/promise');

async function addManyLogs() {
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
    console.log('Adding 60 test log entries to test timeline limit...');
    
    const actions = ['LOGIN', 'LOGOUT', 'CREATE', 'UPDATE', 'DELETE', 'DISPATCH', 'ARRIVE', 'RESOLVE', 'STATUS_CHANGE', 'EXPORT'];
    const entityTypes = ['USER', 'INCIDENT', 'VEHICLE', 'DEPARTMENT', 'DISPATCH', 'NOTIFICATION'];
    const statuses = ['SUCCESS', 'FAILED', 'PENDING'];
    
    for (let i = 0; i < 60; i++) {
      const action = actions[Math.floor(Math.random() * actions.length)];
      const entityType = entityTypes[Math.floor(Math.random() * entityTypes.length)];
      const status = statuses[Math.floor(Math.random() * statuses.length)];
      const userId = Math.random() > 0.3 ? [13, 16, 14, 17][Math.floor(Math.random() * 4)] : null;
      const userRole = userId ? ['Superadmin', 'Admin', 'Citizen'][Math.floor(Math.random() * 3)] : 'SYSTEM';
      
      await db.query(
        'INSERT INTO system_logs (user_ID, user_role, action, entity_type, entity_id, status, details, ip_address) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [userId, userRole, action, entityType, i + 100, status, `Test log entry #${i + 1} for ${action} on ${entityType}`, userId ? '192.168.1.' + (100 + i) : null]
      );
      
      if ((i + 1) % 10 === 0) {
        console.log(`Added ${i + 1} logs...`);
      }
    }

    console.log('60 test logs added successfully!');
    
    // Check total count
    const [count] = await db.query('SELECT COUNT(*) as count FROM system_logs');
    console.log(`Total logs in database: ${count[0].count}`);
    
  } catch (err) {
    console.error('Error adding test logs:', err.message);
  } finally {
    await db.end();
  }
}

addManyLogs();