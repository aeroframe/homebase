<?php
// Homebase Map App (MVP placeholder)
// Later: embed your Move ADS-B Watcher map here (Leaflet/Mapbox/etc).

$dump1090 = "http://127.0.0.1:8080/data/aircraft.json"; // if you proxy; otherwise use dump1090-fa paths
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Homebase</title>
<style>
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif; background:#0b0d12; color:#fff; }
  .wrap { padding:22px; max-width:900px; margin:0 auto; }
  .card { background:#141824; border:1px solid #252a3d; border-radius:14px; padding:18px; margin-top:14px; }
  a { color:#4f7cff; }
  code { font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace; color:#9aa3c7; }
</style>
</head>
<body>
<div class="wrap">
  <h1>Homebase</h1>
  <div class="card">
	<h3>✅ Installed</h3>
	<p>This is the Homebase map app root (<code>/var/www/homebase</code>).</p>
	<p><a href="/setup/">Open Setup</a></p>
  </div>

  <div class="card">
	<h3>Next</h3>
	<p>Replace this page with your Move ADS-B Watcher map UI (Leaflet/Mapbox) and point it at:</p>
	<p><code>dump1090-fa JSON</code> + <code>dump978-fa JSON</code></p>
  </div>
</div>
</body>
</html>