<?php
session_start();

$ch = curl_init('https://aerofra.me/api/auth/user.php');
curl_setopt_array($ch, [
	CURLOPT_RETURNTRANSFER => true,
	CURLOPT_TIMEOUT => 5
]);
$response = curl_exec($ch);
curl_close($ch);

$user = json_decode($response, true);

if (
	isset($user['account_type']) &&
	in_array($user['account_type'], ['LineTech', 'LineOps'], true)
) {
	$_SESSION['user'] = $user;
	header('Location: /');
	exit;
}

header('Location: /login.php?error=unauthorized');
exit;