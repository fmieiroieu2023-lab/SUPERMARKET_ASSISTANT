// App shell only (online-only app, DECISIONS D3): cache the page and its files so the app opens fast.
// Data calls to Supabase are never cached and never queued. Also shows the morning notification (step 6).
const CACHE = "shell-v2";
self.addEventListener("install", (e) => { self.skipWaiting(); e.waitUntil(caches.open(CACHE).then((c) => c.addAll(["/"]))); });
self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== self.location.origin) return;   // Supabase etc. go straight to the network
  e.respondWith(
    fetch(e.request).then((res) => { if (res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(e.request, copy)); } return res; })   // never cache an error page
      .catch(() => caches.match(e.request).then((m) => m || caches.match("/")))
  );
});

// Morning summary (daily-digest). Payload: { title, body, count, url }.
self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { title: "Pantry", body: e.data ? e.data.text() : "" }; }
  const jobs = [self.registration.showNotification(d.title || "Pantry", {
    body: d.body || "", icon: "/icon-192.png", badge: "/icon-192.png", tag: "digest", data: { url: d.url || "/" },
  })];
  if (typeof d.count === "number" && self.navigator.setAppBadge) jobs.push(d.count > 0 ? self.navigator.setAppBadge(d.count) : self.navigator.clearAppBadge());
  e.waitUntil(Promise.all(jobs).catch(() => undefined));
});
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || "/";
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((cs) => {
    const c = cs.find((x) => "focus" in x);
    return c ? c.focus() : self.clients.openWindow(url);
  }));
});
