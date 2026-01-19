<?php
session_start();

if (!isset($_GET['success']) || $_GET['success'] !== '1') {
	header('Location: /login.php');
	exit;
}

$email = $_GET['email'] ?? null;

if (!$email) {
	header('Location: /login.php');
	exit;
}

$_SESSION['user'] = [
	'email' => $email,
];

header('Location: /');
exit;