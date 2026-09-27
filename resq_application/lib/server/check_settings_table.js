const mysql = require('mysql2/promise');

async function check() {
  const db = mysql.createPool({
    host: 'localhost',
    user: 'root',
    password: '',
    database: 'resq_db',
    waitForConnections: true,
    connectionLimit: 5,
  });

  try {
    const [tables] = await db.query("SHOW TABLES");
    console.log('Tables in resq_db:');
    tables.forEach(t => console.log(' - ' + Object.values(t)[0]));

    const [hasSettings] = await db.query("SHOW TABLES LIKE 'user_settings'");
    if (hasSettings.length > 0) {
      console.log('\nuser_settings table EXISTS! Structure:');
      const [columns] = await db.query("DESCRIBE user_settings");
      columns.forEach(c => console.log(`   ${c.Field} (${c.Type}, Default: ${c.Default})`));
      
      const [rows] = await db.query("SELECT * FROM user_settings");
      console.log(`\nRows count: ${rows.length}`);
      if (rows.length > 0) {
        console.log('Sample row:', rows[0]);
      }
    } else {
      console.log('\nuser_settings table DOES NOT EXIST!');
    }
  } catch (err) {
    console.error('Error:', err.message);
  } finally {
    await db.end();
  }
}

check();
