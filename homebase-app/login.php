<?php
session_start();

if (isset($_SESSION['user'])) {
	header('Location: /');
	exit;
}

$error = $_GET['error'] ?? null;
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
		<div class="error">Authentication service unavailable.</div>
	<?php endif; ?>

	<form id="loginForm" autocomplete="off">
		<input type="email" id="email" placeholder="Email" required autofocus>
		<input type="password" id="password" placeholder="Password" required>
		<button type="submit">Sign In</button>
	</form>

	<div class="footer">
		Don’t have an account?
		<a href="https://aerofra.me" target="_blank" rel="noopener">Sign up at aerofra.me</a>
	</div>
</div>

<script>
document.getElementById('loginForm').addEventListener('submit', async (e) => {
	e.preventDefault();

	const email    = document.getElementById('email').value.trim();
	const password = document.getElementById('password').value;

	if (!email || !password) return;

	try {
		/* Step 1: Authenticate via local Homebase proxy */
		const res = await fetch('http://aerofra.me/api/auth/login.php', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ email, password })
		});

		if (!res.ok) {
			window.location.href = '/login.php?error=network';
			return;
		}

		const data = await res.json();

		if (
			!data.success ||
			!data.user ||
			!['LineTech', 'LineOps'].includes(data.user.account_type)
		) {
			window.location.href = '/login.php?error=unauthorized';
			return;
		}

		/* Step 2: Store session locally */
		const sessionRes = await fetch('/session.php', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(data.user)
		});

		if (sessionRes.ok) {
			window.location.href = '/';
		} else {
			window.location.href = '/login.php?error=network';
		}

	} catch (err) {
		console.error(err);
		window.location.href = '/login.php?error=network';
	}
});
</script>

</body>
</html>