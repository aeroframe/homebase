<?php
session_start();

$token = $_GET['token'] ?? null;
if (!$token) {
  header("Location: /login.php?error=token");
  exit;
}

// Verify token with Aeroframe (server-to-server, no CORS issues)
$verifyUrl = "https://aerofra.me/homebase-login/verify.php";

$payload = json_encode([
  "token" => $token
]);

$ch = curl_init($verifyUrl);
curl_setopt_array($ch, [
  CURLOPT_RETURNTRANSFER => true,
  CURLOPT_POST => true,
  CURLOPT_HTTPHEADER => ["Content-Type: application/json"],
  CURLOPT_POSTFIELDS => $payload,
  CURLOPT_TIMEOUT => 10,
]);

$response = curl_exec($ch);
$errno = curl_errno($ch);
$http = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

if ($errno || $http !== 200 || !$response) {
  header("Location: /login.php?error=network");
  exit;
}

$data = json_decode($response, true);
if (!is_array($data) || empty($data['success']) || empty($data['user'])) {
  header("Location: /login.php?error=token");
  exit;
}

// Enforce account type on Homebase too (defense in depth)
$acct = $data['user']['account_type'] ?? '';
if (!in_array($acct, ['LineTech', 'LineOps'], true)) {
  header("Location: /login.php?error=unauthorized");
  exit;
}

// Save minimal user data in local session
$_SESSION['user'] = [
  "email" => $data['user']['email'] ?? '',
  "name" => $data['user']['name'] ?? '',
  "account_type" => $acct,
];

// Go to app
header("Location: /");
exit;