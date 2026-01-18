<?php
$ip = $_SERVER['SERVER_ADDR'];
?>

<!DOCTYPE html>
<html>
<head>
  <title>Homebase Feeds</title>
  <meta charset="utf-8">
  <style>
    body { font-family: sans-serif; background:#0b0b0b; color:#eee; }
    a { color:#4da3ff; }
    pre { background:#111; padding:10px; overflow:auto; max-height:300px; }
    .box { margin-bottom:30px; }
  </style>
</head>
<body>

<h1>✈️ Homebase Feeds</h1>
<p>Device: <?= $ip ?></p>

<div class="box">
  <h2>dump1090 (ADS-B)</h2>
  <a href="http://<?= $ip ?>:30047/data/aircraft.json" target="_blank">
    JSON Feed
  </a>
  <pre id="adsb"></pre>
</div>

<div class="box">
  <h2>dump978 (UAT)</h2>
  <a href="http://<?= $ip ?>:30979" target="_blank">
    JSON Feed
  </a>
  <pre id="uat"></pre>
</div>

<script>
async function load(url, el) {
  try {
    const r = await fetch(url);
    const j = await r.json();
    document.getElementById(el).textContent =
      JSON.stringify(j, null, 2);
  } catch {
    document.getElementById(el).textContent = 'No data';
  }
}

load('http://<?= $ip ?>:30047/data/aircraft.json','adsb');
load('http://<?= $ip ?>:30979','uat');
</script>

</body>
</html>