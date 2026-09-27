const mysql = require('mysql2/promise');

async function migrate() {
  const db = mysql.createPool({
    host: 'localhost',
    user: 'root',
    password: '',
    database: 'resq_db',
    waitForConnections: true,
    connectionLimit: 5,
  });

  try {
    console.log('1. Checking for existing duplicate rows in user_settings...');
    const [rows] = await db.query('SELECT setting_id, user_ID FROM user_settings ORDER BY setting_id ASC');
    console.log(`Found ${rows.length} rows.`);

    // Group by user_ID and delete duplicates keeping the latest setting_id
    const seen = new Map();
    for (const row of rows) {
      if (seen.has(row.user_ID)) {
        const oldId = seen.get(row.user_ID);
        console.log(`Removing older duplicate setting_id ${oldId} for user_ID ${row.user_ID}`);
        await db.query('DELETE FROM user_settings WHERE setting_id = ?', [oldId]);
      }
      seen.set(row.user_ID, row.setting_id);
    }

    console.log('2. Checking if UNIQUE index on user_ID already exists...');
    const [indexes] = await db.query("SHOW INDEXES FROM user_settings WHERE Column_name = 'user_ID' AND Non_unique = 0");
    if (indexes.length === 0) {
      console.log('Adding UNIQUE KEY uk_user_settings_user on user_ID...');
      await db.query('ALTER TABLE user_settings ADD UNIQUE KEY uk_user_settings_user (user_ID)');
      console.log('UNIQUE KEY added successfully!');
    } else {
      console.log('UNIQUE KEY already exists on user_ID.');
    }

    console.log('3. Verifying updated indexes...');
    const [updatedIndexes] = await db.query("SHOW INDEXES FROM user_settings WHERE Column_name = 'user_ID'");
    console.log(updatedIndexes);
  } catch (err) {
    console.error('Migration error:', err);
    process.exit(1);
  } finally {
    await db.end();
  }
}

migrate();
