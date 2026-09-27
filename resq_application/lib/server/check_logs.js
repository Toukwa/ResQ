const mysql = require('mysql2/promise');

async function checkLogs() {
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
    console.log('Checking for FAILED status logs...');
    const [failedLogs] = await db.query(
      'SELECT * FROM system_logs WHERE status = "FAILED" ORDER BY timestamp DESC LIMIT 10'
    );
    
    if (failedLogs.length > 0) {
      console.log('Found FAILED logs:');
      failedLogs.forEach(log => {
        console.log(`- ID: ${log.log_id}, Action: ${log.action}, Entity: ${log.entity_type}, Details: ${log.details}`);
      });
    } else {
      console.log('No FAILED logs found');
    }
    
    console.log('\nAll recent logs:');
    const [recentLogs] = await db.query(
      'SELECT log_id, action, entity_type, status, details, timestamp FROM system_logs ORDER BY timestamp DESC LIMIT 10'
    );
    
    recentLogs.forEach(log => {
      console.log(`- ID: ${log.log_id}, Action: ${log.action}, Status: ${log.status}, Details: ${log.details?.substring(0, 50)}...`);
    });
    
  } catch (err) {
    console.error('Error checking logs:', err.message);
  } finally {
    await db.end();
  }
}

checkLogs();