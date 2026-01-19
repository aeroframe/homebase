<?php
require_once __DIR__ . '/auth.php';

$device_id = get_homebase_device_id();
$return = 'http://' . $_SERVER['HTTP_HOST'] . '/auth/callback.php';

$loginUrl = 'https://aerofra.me/auth/?' . http_build_query([
  'return' => $return,
  'device_id' => $device_id,
]);
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Homebase Login</title>
<link rel="stylesheet" href="/assets/homebase.css">
</head>
<body>

<div class="login-card">
  <img src="/assets/logo.svg" class="logo" alt="Homebase">
  <h1>Homebase</h1>
  <p class="subtitle">Secure aircraft surveillance node</p>

  <a class="btn" href="<?= htmlspecialchars($loginUrl) ?>">
	Sign in with Aeroframe Cloud
  </a>

  <p class="muted">Device: <?= htmlspecialchars($device_id) ?></p>
</div>

</body>
</html>