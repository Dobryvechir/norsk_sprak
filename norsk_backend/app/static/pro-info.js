// What the Pro plan gives, shown on /app/plan/ (sign-up) and /app/upgrade/ (Basic users).
// The limits are those of the "Advanced" group, read from GET /api/plan/pro-info.
// Usage: <div id="pro-info"></div> ... showProInfo(document.getElementById('pro-info'));
(function () {
  const TERMS_URL = '../terms_of_sale';  // /app/terms_of_sale
  const PRIVACY_URL = '../privacy_policy';  // /app/privacy_policy

  function item(list, text) {
    const li = document.createElement('li');
    li.textContent = text;
    list.appendChild(li);
  }

  function link(href, text) {
    const a = document.createElement('a');
    a.href = href; a.textContent = text; a.target = '_blank'; a.rel = 'noopener';
    return a;
  }

  window.showProInfo = async function (container) {
    const list = document.createElement('ul');
    item(list, 'Access to AI services');
    container.replaceChildren(list);
    try {
      const r = await fetch('../../api/plan/pro-info');
      if (r.ok) {
        const info = await r.json();
        const limits = info.limits || {};
        if (info.aiMonthlyMinutes) item(list, `AI transcription: up to ${info.aiMonthlyMinutes} minutes of audio a month`);
        if (!limits.anonymous) {
          item(list, `Chat: up to ${limits.chatPerDayKb} kB of messages a day`);
          item(list, `Chat: up to ${limits.subgroupLimitPerYear} new subgroups a year`);
          item(list, `Chat messages are kept for ${limits.expirationDays} days`);
        }
      }
    } catch (e) { /* the limits are optional; the rest of the page still works */ }
    const legal = document.createElement('p');
    legal.className = 'legal';
    legal.append(link(TERMS_URL, 'Terms of sale'), ' · ', link(PRIVACY_URL, 'Privacy policy'));
    container.appendChild(legal);
  };
})();
