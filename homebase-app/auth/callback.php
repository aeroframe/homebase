<?php
session_start();

/**
 * TEMPORARY: Inline shared secret
 * MUST match auth/login_submit.php
 */
$HOMEBASE_AUTH_SECRET = 'c6da003ff39556572305e4e8c2796c0e2e109b3cddae547194ceb57ddd7ee960';

/**
 * Validate incoming token
 */
$token = $_GET['token'] ?? '';
$sig   = $_GET['sig'] ?? '';

if (!$token || !$sig) {
	http_response_code(403);
	die('Invalid auth callback.');
}

/**
 * Verify signature (USE INLINE SECRET)
 */
$expected = hash_hmac('sha256', $token, $HOMEBASE_AUTH_SECRET);

if (!hash_equals($expected, $sig)) {
	http_response_code(403);
	die('Signature verification failed.');
}

/**
 * Decode token payload
 */
$data = json_decode(base64_decode($token), true);

if (!$data || !is_array($data)) {
	http_response_code(403);
	die('Invalid token payload.');
}

/**
 * Expiration check
 */
if (empty($data['exp']) || $data['exp'] < time()) {
	http_response_code(403);
	die('Token expired.');
}

/**
 * Enforce Homebase access
 */
$accountType = strtolower($data['account_type'] ?? '');

if (!in_array($accountType, ['linetech', 'lineops'], true)) {
	http_response_code(403);
	die('Account not authorized for Homebase.');
}

/**
 * SUCCESS — establish Homebase session
 */
session_regenerate_id(true);

$_SESSION['user'] = [
	'email'         => $data['email'],
	'account_type'  => $accountType,
	'authenticated' => true,
	'login_time'    => time(),
];

/**
 * Redirect into Homebase
 */
header('Location: /');
exit;