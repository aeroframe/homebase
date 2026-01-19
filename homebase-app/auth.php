<?php
/**
 * Homebase authentication helper
 * --------------------------------
 * - Validates Aeroframe-issued auth token
 * - Establishes Homebase session
 */

if (session_status() !== PHP_SESSION_ACTIVE) {
  session_start();
}

/**
 * Configuration
 */
$HOMEBASE_SECRET = getenv('HOMEBASE_AUTH_SECRET');

if (!$HOMEBASE_SECRET) {
  http_response_code(500);
  die('Homebase misconfigured: missing HOMEBASE_AUTH_SECRET');
}

/**
 * Require user to be logged in
 */
function require_login(): void
{
  if (!isset($_SESSION['user'])) {
    header('Location: /login.php');
    exit;
  }
}

/**
 * Handle callback from Aeroframe Cloud
 * /auth/callback.php includes this file
 */
function handle_callback(): void
{
  global $HOMEBASE_SECRET;

  $token = $_GET['token'] ?? '';
  $sig   = $_GET['sig'] ?? '';

  if (!$token || !$sig) {
    http_response_code(403);
    die('Missing authentication token.');
  }

  // Verify signature
  $expectedSig = hash_hmac('sha256', $token, $HOMEBASE_SECRET);
  if (!hash_equals($expectedSig, $sig)) {
    http_response_code(403);
    die('Invalid authentication signature.');
  }

  // Decode token
  $payload = json_decode(base64_decode($token), true);
  if (!$payload || !is_array($payload)) {
    http_response_code(403);
    die('Invalid authentication payload.');
  }

  // Expiration check
  if (empty($payload['exp']) || time() > $payload['exp']) {
    http_response_code(403);
    die('Authentication token expired.');
  }

  // Account type enforcement
  $accountType = strtolower($payload['account_type'] ?? '');
  if (!in_array($accountType, ['linetech', 'lineops'], true)) {
    http_response_code(403);
    die('Account not authorized for Homebase.');
  }

  // Establish Homebase session
  $_SESSION['user'] = [
    'email'        => $payload['email'],
    'account_type' => $accountType,
    'authenticated_at' => time(),
  ];

  // Redirect into app
  header('Location: /');
  exit;
}