<?php
session_start();

/**
 * Generate a stable Homebase device ID
 * - No files
 * - No install dependency
 * - Stable across reboots
 */
function get_device_id(): string {
	$hostname = gethostname() ?: 'homebase';
	$machineId = @file_get_contents('/etc/machine-id') ?: uniqid();
	$hash = substr(hash('sha256', $hostname . $machineId), 0, 12);
	return 'HB-' . $hash;
}

$return = 'http://homebase.local/auth/callback.php';
$device_id = get_device_id();
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
	<img src="/assets/logo.svg" class="logo" alt="Homebase">

	<h1>Homebase</h1>
	<p class="subtitle">
		Secure aircraft surveillance node<br>
		powered by Aeroframe
	</p>

	<div class="context-box">
		You are signing into a <strong>Homebase receiver</strong>.<br>
		Access is limited to <strong>LineTech</strong> and <strong>LineOps</strong> accounts.
	</div>

	<a class="btn primary"
	   href="https://aerofra.me/auth/
		 ?return=<?= urlencode($return) ?>
		 &device_id=<?= urlencode($device_id) ?>">
		Login with Aeroframe Cloud
	</a>

	<p class="device-id">
		Device: <?= htmlspecialchars($device_id) ?>
	</p>
</div>

</body>
</html>