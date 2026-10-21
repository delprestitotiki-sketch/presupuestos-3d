/* Presupuestos 3D: funciona sin conexión.
   La app y el catálogo se buscan primero en la red (para recibir actualizaciones)
   y, si no hay conexión, se usan desde la copia guardada. */
const CACHE = 'presupuestos3d-20261021111357';
const SHELL = [
  './',
  'index.html',
  'manifest.webmanifest',
  'catalog.json',
  'vendor/jspdf.umd.min.js',
  'icons/icon-192.png',
  'icons/icon-512.png',
  'icons/maskable-512.png',
  'icons/apple-touch-icon.png',
  'icons/favicon-32.png'
];

self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) { return c.addAll(SHELL); }).then(function () { return self.skipWaiting(); }));
});

self.addEventListener('activate', function (e) {
  e.waitUntil(
    caches.keys()
      .then(function (keys) { return Promise.all(keys.filter(function (k) { return k !== CACHE; }).map(function (k) { return caches.delete(k); })); })
      .then(function () { return self.clients.claim(); })
  );
});

function networkFirst(req) {
  return fetch(req).then(function (res) {
    if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(function (c) { c.put(req, copy); }); }
    return res;
  }).catch(function () {
    return caches.match(req, { ignoreSearch: true }).then(function (r) { return r || caches.match('index.html'); });
  });
}

function cacheFirst(req) {
  return caches.match(req).then(function (r) {
    return r || fetch(req).then(function (res) {
      if (res.ok || res.type === 'opaque') { const copy = res.clone(); caches.open(CACHE).then(function (c) { c.put(req, copy); }); }
      return res;
    });
  });
}

self.addEventListener('fetch', function (e) {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  const same = url.origin === self.location.origin;
  if (same && (req.mode === 'navigate' || /\/(index\.html|catalog\.json)$/.test(url.pathname))) {
    e.respondWith(networkFirst(req));
  } else if (same || /fonts\.(googleapis|gstatic)\.com$/.test(url.hostname)) {
    e.respondWith(cacheFirst(req));
  }
});
