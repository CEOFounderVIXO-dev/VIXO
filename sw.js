self.addEventListener("push", event => {
  let data = {};

  try {
    data = event.data ? event.data.json() : {};
  } catch (e) {
    data = {
      title: "VIXO MARKET BOARD",
      body: event.data ? event.data.text() : "New analysis published."
    };
  }

  const title = data.title || "VIXO MARKET BOARD";

  const options = {
    body: data.body || "New analysis published.",
    icon: "/VIXO/IMG_20260918_064032.jpg",
    badge: "/VIXO/IMG_20260918_064032.jpg",
    data: {
      url: "https://ceofoundervixo-dev.github.io/VIXO/"
    }
  };

  event.waitUntil(
    self.registration.showNotification(title, options)
  );
});

self.addEventListener("notificationclick", event => {
  event.notification.close();

  event.waitUntil(
    clients.openWindow(
      event.notification.data.url
    )
  );
});
