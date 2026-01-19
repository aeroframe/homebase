<?php
session_start();

if (isset($_SESSION['user'])) {
	header('Location: /');
	exit;
}

// Stable per-device ID
$hostname  = gethostname() ?: 'homebase';
$device_id = 'HB-' . substr(hash('sha256', $hostname), 0, 12);

// Callback URL
$return = 'http://homebase.local/auth/callback.php';

// Build auth URL safely
$auth_url = 'https://aerofra.me/auth/?' . http_build_query([
	'return'    => $return,
	'device_id' => $device_id
]);
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Homebase — Sign In</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="stylesheet" href="/assets/homebase.css">
</head>
<body>

<div class="login-card">
	<img src="/assets/logo.svg" class="logo">

	<h1>Homebase</h1>
	<p class="subtitle">
		Secure aircraft surveillance node<br>
		powered by Aeroframe
	</p>

	<a class="btn-primary" href="<?= htmlspecialchars($auth_url) ?>">
		Sign in with Aeroframe Cloud
	</a>

	<p class="muted">
		Device ID: <?= htmlspecialchars($device_id) ?>
	</p>
</div>

</body>
</html>