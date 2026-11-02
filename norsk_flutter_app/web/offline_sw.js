// Lets the web app start without a connection, so the chapters saved on this device can be used.
// Every file the app loads is kept in a cache when it is fetched:
//  - the app's own files (same site): from the network when online, so a new version is picked up;
//    from the cache when offline;
//  - Flutter's engine and fonts (www.gstatic.com, fonts.gstatic.com, fonts.googleapis.com): from the
//    cache when there, because those URLs never change their content.
// API calls (/api/...) and audio are never cached here: saved chapters are kept by the app itself.
'use strict';

const CACHE = 'norsk-app-v1';
const CDN_HOSTS = ['www.gstatic.com', 'fonts.gstatic.com', 'fonts.googleapis.com'];

self.addEventListener('install', (event) => {
  // The page itself, so the app opens offline even if nothing else was cached yet.
  event.waitUntil(caches.open(CACHE).then((cache) => cache.add('./')).catch(() => {}));
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const name of await caches.keys()) {
      if (name !== CACHE) await caches.delete(name);
    }
    await self.clients.claim();
  })());
});

async function save(request, response) {
  if (response.ok && (response.type === 'basic' || response.type === 'cors')) {
    const cache = await caches.open(CACHE);
    await cache.put(request, response.clone());
  }
  return response;
}

async function networkFirst(request) {
  try {
    return await save(request, await fetch(request));
  } catch (e) {
    const cached = await caches.match(request, { ignoreSearch: request.mode === 'navigate' })
      || (request.mode === 'navigate' ? await caches.match('./') : undefined);
    if (cached) return cached;
    throw e;
  }
}

async function cacheFirst(request) {
  return (await caches.match(request)) || save(request, await fetch(request));
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET' || request.headers.has('range')) return;
  const url = new URL(request.url);
  if (url.origin === self.location.origin) {
    if (url.pathname.includes('/api/')) return;
    event.respondWith(networkFirst(request));
  } else if (CDN_HOSTS.includes(url.hostname)) {
    event.respondWith(cacheFirst(request));
  }
});
