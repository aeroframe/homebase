<?php
session_start();

if (isset($_SESSION['user'])) {
	header('Location: /');
	exit;
}

$error = null;

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
	$email = trim($_POST['email'] ?? '');
	$password = $_POST['password'] ?? '';

	if ($email !== '' && $password !== '') {

		$ch = curl_init('https://aerofra.me/login_submit.php');

		curl_setopt_array($ch, [
			CURLOPT_POST => true,
			CURLOPT_POSTFIELDS => http_build_query([
				// 🔑 CRITICAL FIX:
				// login_submit.php expects THESE names
				'username' => $email,
				'password' => $password
			]),
			CURLOPT_RETURNTRANSFER => true,
			CURLOPT_HEADER => true,
			CURLOPT_FOLLOWLOCATION => false,
			CURLOPT_TIMEOUT => 10
		]);

		$response = curl_exec($ch);
		$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
		curl_close($ch);

		// Successful login on Aeroframe = redirect
		if ($httpCode === 302) {

			// Fetch user profile (same as real app)
			$ch = curl_init('https://aerofra.me/api/auth/user.php');
			curl_setopt_array($ch, [
				CURLOPT_RETURNTRANSFER => true,
				CURLOPT_TIMEOUT => 5
			]);
			$userJson = curl_exec($ch);
			curl_close($ch);

			$user = json_decode($userJson, true);

			if (
				isset($user['account_type']) &&
				in_array($user['account_type'], ['LineTech', 'LineOps'], true)
			) {
				$_SESSION['user'] = $user;
				header('Location: /');
				exit;
			}

			$error = 'unauthorized';
		} else {
			$error = 'invalid';
		}
	} else {
		$error = 'invalid';
	}
}
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

	<form method="POST">
		<input type="email" name="email" placeholder="Email" required>
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