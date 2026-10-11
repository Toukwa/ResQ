// Password reset page. Firebase's reset email template (Firebase console >
// Authentication > Templates > Password reset) links here with the reset code.
(function () {
  const params = new URLSearchParams(location.search);
  const code = params.get('oobCode');
  const key = params.get('apiKey') || 'AIzaSyDHBxLSpKSbICYzLekvrysNP7dobVZFK6s';
  const url = 'https://identitytoolkit.googleapis.com/v1/accounts:resetPassword?key=' + encodeURIComponent(key);
  const $ = (id) => document.getElementById(id);

  function show(id) {
    ['loading', 'form', 'done', 'failed'].forEach((s) => { $(s).hidden = s !== id; });
  }

  async function call(body) {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error((data.error && data.error.message) || 'UNKNOWN');
    return data;
  }

  // Same rule as the app (lib/services/password_policy.dart)
  function checkPassword(pw) {
    if (pw.length < 8 || !/[a-z]/.test(pw) || !/[0-9]/.test(pw)) {
      return 'Password must be at least 8 characters, including a lowercase letter and a number.';
    }
    return null;
  }

  document.querySelectorAll('.toggle').forEach((btn) => {
    btn.addEventListener('click', () => {
      const input = $(btn.dataset.for);
      const showing = input.type === 'text';
      input.type = showing ? 'password' : 'text';
      btn.textContent = showing ? 'Show' : 'Hide';
    });
  });

  // The email template links here as /reset?from=%LINK%, so the original link's
  // own query (mode, oobCode, apiKey) arrives as extra params; mode may be absent.
  const mode = params.get('mode');
  if (!code || (mode && mode !== 'resetPassword')) {
    $('failMsg').textContent = 'This link is not a ResQ password reset link.';
    show('failed');
    return;
  }

  call({ oobCode: code })
    .then((data) => { $('email').textContent = data.email || ''; show('form'); $('pw').focus(); })
    .catch(() => show('failed'));

  $('form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const pw = $('pw').value;
    const err = pw !== $('pw2').value ? 'Passwords do not match.' : checkPassword(pw);
    $('error').hidden = !err;
    if (err) { $('error').textContent = err; return; }

    $('submit').disabled = true;
    $('submit').textContent = 'Saving…';
    try {
      await call({ oobCode: code, newPassword: pw });
      show('done');
    } catch (ex) {
      if (/EXPIRED|INVALID_OOB/.test(ex.message)) { show('failed'); return; }
      $('error').textContent = /WEAK_PASSWORD/.test(ex.message)
        ? 'That password is too weak. Try a longer one.'
        : 'Could not save the password. Check your internet and try again.';
      $('error').hidden = false;
      $('submit').disabled = false;
      $('submit').textContent = 'Save New Password';
    }
  });
})();
