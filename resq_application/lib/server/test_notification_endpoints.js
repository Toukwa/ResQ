const http = require('http');

// Test notification endpoints
console.log('Testing notification endpoints...');

// Test 1: Get notifications for user 13
const options1 = {
  hostname: 'localhost',
  port: 3000,
  path: '/api/notifications/13',
  method: 'GET'
};

const req1 = http.request(options1, (res) => {
  let data = '';
  res.on('data', (chunk) => { data += chunk; });
  res.on('end', () => {
    console.log('GET /api/notifications/13 Response:', res.statusCode, data);
    
    // Test 2: Add a new notification
    const postData = JSON.stringify({
      recipientId: 13,
      title: 'Test Notification from Server',
      message: 'This is a test notification created at ' + new Date().toISOString()
    });
    
    const options2 = {
      hostname: 'localhost',
      port: 3000,
      path: '/api/notifications',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData)
      }
    };
    
    const req2 = http.request(options2, (res) => {
      let data2 = '';
      res.on('data', (chunk) => { data2 += chunk; });
      res.on('end', () => {
        console.log('POST /api/notifications Response:', res.statusCode, data2);
        
        // Test 3: Get notifications again to verify
        const req3 = http.request(options1, (res) => {
          let data3 = '';
          res.on('data', (chunk) => { data3 += chunk; });
          res.on('end', () => {
            console.log('GET /api/notifications/13 (after add) Response:', res.statusCode, data3);
          });
        });
        req3.on('error', (e) => console.error('Request 3 error:', e.message));
        req3.end();
      });
    });
    req2.on('error', (e) => console.error('Request 2 error:', e.message));
    req2.write(postData);
    req2.end();
  });
});

req1.on('error', (e) => console.error('Request 1 error:', e.message));
req1.end();