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
		You are signing into a <strong>Homebase receiver</strong>.
		Access is limited to <strong>LineTech</strong> and <strong>LineOps</strong> accounts.
	</div>

	<?php if ($error === 'invalid'): ?>
		<div class="error">Invalid email or password.</div>
	<?php elseif ($error === 'unauthorized'): ?>
		<div class="error">Your account does not have access to Homebase.</div>
	<?php endif; ?>

	<form id="loginForm">
		<input type="email" id="email" placeholder="Email" required>
		<input type="password" id="password" placeholder="Password" required>
		<button type="submit">Sign In</button>
	</form>

	<div class="footer">
		Don’t have an account?
		<a href="https://aerofra.me" target="_blank">Sign up at aerofra.me</a>
	</div>
</div>

<script>
document.getElementById('loginForm').addEventListener('submit', async (e) => {
	e.preventDefault();

	const res = await fetch('https://aerofra.me/api/auth/login.php', {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({
			email: email.value,
			password: password.value
		})
	});

	const data = await res.json();

	if (data.success && ['LineTech','LineOps'].includes(data.user.account_type)) {
		const r = await fetch('/session.php', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(data.user)
		});
		if (r.ok) location.href = '/';
	} else {
		location.href = '/login.php?error=invalid';
	}
});
</script>

</body>
</html>