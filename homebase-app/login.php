<?php
session_start();

if (isset($_SESSION['user'])) {
  header("Location: /");
  exit;
}

$error = $_GET['error'] ?? null;

// Basic device id: stable across reboots on Linux
$machineId = @trim(file_get_contents('/etc/machine-id'));
if (!$machineId) $machineId = bin2hex(random_bytes(8));
$deviceId = "HB-" . substr(preg_replace('/[^a-f0-9]/i', '', $machineId), 0, 12);

// Return URL must be absolute so Aeroframe can redirect back
$scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? "https" : "http";
$host = $_SERVER['HTTP_HOST'] ?? "homebase.local";
$returnUrl = $scheme . "://" . $host . "/session.php";

// Aeroframe endpoint
$aeroframeLogin = "https://aerofra.me/homebase-login/?return=" . urlencode($returnUrl) . "&device_id=" . urlencode($deviceId);
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

  <?php if ($error === 'invalid'): ?>
	<div class="error">Invalid email or password.</div>
  <?php elseif ($error === 'unauthorized'): ?>
	<div class="error">Your account does not have access to Homebase.</div>
  <?php elseif ($error === 'network'): ?>
	<div class="error">Could not reach Aeroframe Cloud. Try again.</div>
  <?php elseif ($error === 'token'): ?>
	<div class="error">Sign-in token expired or invalid. Try again.</div>
  <?php endif; ?>

  <a class="button" href="<?= htmlspecialchars($aeroframeLogin, ENT_QUOTES); ?>">
	Sign in with Aeroframe Cloud
  </a>

  <div class="footer">
	Don’t have an account?
	<a href="https://aerofra.me" target="_blank" rel="noreferrer">Sign up at aerofra.me</a>
  </div>
</div>

</body>
</html>