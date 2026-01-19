<?php
/**
 * Homebase → Aeroframe Cloud login redirect
 */

$host = $_SERVER['HTTP_HOST'];

/**
 * Return URL back to Homebase root
 */
$return = 'http://' . $host . '/';

/**
 * Stable device ID (hostname-based)
 * Example: HB-a699b8ad8702
 */
$hostname = gethostname() ?: $host;
$deviceId = 'HB-' . substr(hash('sha256', $hostname), 0, 12);

/**
 * Build Aeroframe auth URL
 */
$authUrl = 'https://aerofra.me/auth/?' . http_build_query([
	'return'    => $return,
	'device_id' => $deviceId,
]);

header('Location: ' . $authUrl);
exit;