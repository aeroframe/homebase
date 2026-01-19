<?php
session_start();
require_once __DIR__ . '/../auth.php';

$payload = $_GET['payload'] ?? '';
$sig     = $_GET['sig'] ?? '';

if (!$payload || !$sig) {
  http_response_code(400);
  exit('Missing payload');
}

$secret = getenv('HOMEBASE_AUTH_SECRET');
if (!$secret) {
  http_response_code(500);
  exit('Missing HOMEBASE_AUTH_SECRET');
}

$expected = hash_hmac('sha256', $payload, $secret);
if (!hash_equals($expected, $sig)) {
  http_response_code(403);
  exit('Invalid signature');
}

$data = json_decode(base64_decode($payload), true);
if (!$data) {
  http_response_code(400);
  exit('Invalid payload');
}

if (!in_array($data['account_type'], ['LineTech', 'LineOps'], true)) {
  http_response_code(403);
  exit('Unauthorized');
}

if (!verify_device_id($data['device_id'])) {
  http_response_code(403);
  exit('Device mismatch');
}

// ✅ Success
$_SESSION['user'] = [
  'email' => $data['email'],
  'account_type' => $data['account_type'],
  'device_id' => $data['device_id'],
  'login_at' => time(),
];

header('Location: /');
exit;