const mysql = require('mysql2/promise');
const fs = require('fs');
const path = require('path');

async function updateSchema() {
  const db = mysql.createPool({
    host: 'localhost',
    user: 'root',
    password: '',
    database: 'resq_db',
    waitForConnections: true,
    connectionLimit: 10,
    queueLimit: 0,
    multipleStatements: true
  });

  try {
    const sqlPath = path.join(__dirname, 'database_schema_update.sql');
    const sql = fs.readFileSync(sqlPath, 'utf8');
    
    console.log('Applying database schema update...');
    await db.query(sql);
    console.log('Database schema updated successfully!');
  } catch (err) {
    console.error('Error updating schema:', err.message);
    process.exit(1);
  } finally {
    await db.end();
  }
}

updateSchema();