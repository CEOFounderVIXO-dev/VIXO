self.addEventListener("push", (event) => {
  let data = {};

  try {
    data = event.data ? event.data.json() : {};
  } catch (_) {}

  event.waitUntil(
    self.registration.showNotification(
      data.title || "VIXO MARKET BOARD",
      {
        body: data.body || "Ada update baru.",
        icon: "IMG_20260918_064032.jpg",
        badge: "IMG_20260918_064032.jpg",
        tag: "vixo-analysis",
        renotify: true,
        data: {
          url: data.url || "./"
        }
      }
    )
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();

  const url = event.notification.data?.url || "./";

  event.waitUntil(
    clients.matchAll({
      type: "window",
      includeUncontrolled: true
    }).then((list) => {
      for (const client of list) {
        if ("focus" in client) {
          client.navigate(url);
          return client.focus();
        }
      }

      return clients.openWindow(url);
    })
  );
});
