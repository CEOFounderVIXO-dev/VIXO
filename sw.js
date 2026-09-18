import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

// Public key — aman digunakan di kode
const VAPID_PUBLIC_KEY =
  "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEe5OUBOiuaZRWbPYyMN6fGotBNykagDpklYKqvh+KxKG3sRCiBVY/Y8K8xEv32J/jzOfT3FwhMgCFs0Kktq7Dng==";

// Private key DIAMBIL DARI SUPABASE EDGE FUNCTION SECRET
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY");

if (!VAPID_PRIVATE_KEY) {
  throw new Error("VAPID_PRIVATE_KEY belum dikonfigurasi.");
}

webpush.setVapidDetails(
  "mailto:vixo.notifications@gmail.com",
  VAPID_PUBLIC_KEY,
  VAPID_PRIVATE_KEY
);

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return new Response("Method Not Allowed", {
        status: 405
      });
    }

    const body = await req.json();

    // Dipanggil oleh website untuk mendapatkan public key
    if (body.action === "public-key") {
      return new Response(
        JSON.stringify({
          publicKey: VAPID_PUBLIC_KEY
        }),
        {
          headers: {
            "Content-Type": "application/json"
          }
        }
      );
    }

    // Ambil semua perangkat yang sudah berlangganan push
    const { data: subscriptions, error } = await supabase
      .from("push_subscriptions")
      .select("id, endpoint, p256dh, auth");

    if (error) {
      throw error;
    }

    const payload = JSON.stringify({
      title: body.title || "VIXO MARKET BOARD",
      body: body.message || "Ada update baru.",
      url:
        body.url ||
        "https://ceofoundervixo-dev.github.io/VIXO/"
    });

    let sent = 0;

    for (const sub of subscriptions || []) {
      try {
        await webpush.sendNotification(
          {
            endpoint: sub.endpoint,
            keys: {
              p256dh: sub.p256dh,
              auth: sub.auth
            }
          },
          payload
        );

        sent++;
      } catch (err) {
        // Subscription sudah tidak valid
        if (
          err?.statusCode === 404 ||
          err?.statusCode === 410
        ) {
          await supabase
            .from("push_subscriptions")
            .delete()
            .eq("id", sub.id);
        }
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        sent,
        total: subscriptions?.length || 0
      }),
      {
        headers: {
          "Content-Type": "application/json"
        }
      }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({
        success: false,
        error: String(err?.message || err)
      }),
      {
        status: 500,
        headers: {
          "Content-Type": "application/json"
        }
      }
    );
  }
});
