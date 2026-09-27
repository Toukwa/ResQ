const mysql = require('mysql2/promise');

const dbConfig = {
  host: process.env.DB_HOST || 'localhost',
  user: process.env.DB_USER || 'root',
  password: process.env.DB_PASSWORD || '',
  database: process.env.DB_NAME || 'resq_db',
  port: process.env.DB_PORT ? Number(process.env.DB_PORT) : 3306,
};

async function resetVehiclesToDefault() {
  console.log('[*] Connecting to database...');
  let conn;
  try {
    conn = await mysql.createConnection(dbConfig);
    console.log('[✓] Connected to database!');

    console.log('[*] Altering response_vehicle columns to default NULL...');
    await conn.query(`
      ALTER TABLE response_vehicle
      MODIFY COLUMN plate_no VARCHAR(50) NULL DEFAULT NULL,
      MODIFY COLUMN vehicle_type VARCHAR(50) NULL DEFAULT NULL,
      MODIFY COLUMN dept_ID INT NULL DEFAULT NULL
    `);
    console.log('[✓] Columns plate_no, vehicle_type, dept_ID modified to default NULL.');

    console.log('[*] Resetting existing vehicles to default NULL values...');
    const [result] = await conn.query(`
      UPDATE response_vehicle
      SET plate_no = NULL, vehicle_type = NULL, dept_ID = NULL
    `);
    console.log(`[✓] Reset ${result.affectedRows} existing vehicle(s) to default NULL values!`);
  } catch (err) {
    console.error('[×] Error updating database:', err.message);
  } finally {
    if (conn) await conn.end();
    process.exit(0);
  }
}

resetVehiclesToDefault();
