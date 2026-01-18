<?php
session_start();

if (!isset($_SESSION['user'])) {
	header('Location: /login.php');
	exit;
}

$allowed = ['LineTech', 'LineOps'];

if (!in_array($_SESSION['user']['account_type'], $allowed, true)) {
	session_destroy();
	header('Location: /login.php?error=unauthorized');
	exit;
}