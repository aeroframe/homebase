<?php
session_start();

if (isset($_SESSION['user'])) {
	header('Location: /');
	exit;
}

$error = $_GET['error'] ?? null;
$return = urlencode('https://homebase.local/session.php');
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
		Access is limited to <strong>LineTech</strong> and <strong>LineOps</strong>.
	</div>

	<?php if ($error === 'invalid'): ?>
		<div class="error">Invalid email or password.</div>
	<?php elseif ($error === 'unauthorized'): ?>
		<div class="error">Your account does not have access to Homebase.</div>
	<?php endif; ?>

	<!-- 🚀 THIS IS THE FIX -->
	<form method="POST" action="https://aerofra.me/login_submit.php">
		<input type="hidden" name="redirect" value="<?= $return ?>">
		<input type="email" name="username" placeholder="Email" required>
		<input type="password" name="password" placeholder="Password" required>
		<button type="submit">Sign In</button>
	</form>

	<div class="footer">
		Don’t have an account?
		<a href="https://aerofra.me" target="_blank">Sign up at aerofra.me</a>
	</div>
</div>

</body>
</html>