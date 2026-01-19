<?php
session_start();

/*
Expected query params from Aeroframe:
- success=1
- email
- account_type
*/

if (
	!isset($_GET['success']) ||
	$_GET['success'] !== '1' ||
	!isset($_GET['email'], $_GET['account_type'])
) {
	header('Location: /login.php?error=invalid');
	exit;
}

$allowed = ['LineTech', 'LineOps'];

if (!in_array($_GET['account_type'], $allowed, true)) {
	header('Location: /login.php?error=unauthorized');
	exit;
}

$_SESSION['user'] = [
	'email' => $_GET['email'],
	'account_type' => $_GET['account_type']
];

header('Location: /');
exit;