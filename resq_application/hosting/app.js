// Download links use GitHub's /releases/latest/ URLs, so they always serve the newest
// release as long as it contains ResQ_EOC_Windows.zip and ResQ_EOC.apk.
// This only fills in the version label.
fetch('https://api.github.com/repos/Toukwa/ResQ/releases/latest')
  .then(function (r) { return r.ok ? r.json() : null; })
  .then(function (release) {
    if (!release || !release.tag_name) return;
    var tag = release.tag_name.charAt(0) === 'v' ? release.tag_name : 'v' + release.tag_name;
    document.querySelectorAll('[data-latest-version]').forEach(function (el) { el.textContent = tag; });
  })
  .catch(function () {});
