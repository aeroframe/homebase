<?php
/**
 * Homebase Authentication Helper
 * ===============================
 * Handles:
 *  - Login enforcement
 *  - Aeroframe Cloud callback validation
 *  - Homebase session establishment
 */

if (session_status() !== PHP_SESSION_ACTIVE) {
    session_start();
}

/**
 * ============================================================
 * CONFIGURATION
 * ============================================================
 * TEMPORARY inline secret
 * Move to env var later if desired
 */
$HOMEBASE_AUTH_SECRET = 'c6da003ff39556572305e4e8c2796c0e2e109b3cddae547194ceb57ddd7ee960';

if (!$HOMEBASE_AUTH_SECRET) {
    http_response_code(500);
    die('Homebase misconfigured: missing HOMEBASE_AUTH_SECRET');
}

/**
 * ============================================================
 * REQUIRE LOGIN
 * ============================================================
 */
function require_login(): void
{
    if (
        empty($_SESSION['user']) ||
        empty($_SESSION['user']['authenticated'])
    ) {
        header('Location: /login.php');
        exit;
    }
}

/**
 * ============================================================
 * HANDLE AEROFAME CALLBACK
 * ============================================================
 * Used by /auth/callback.php
 */
function handle_callback(): void
{
    global $HOMEBASE_AUTH_SECRET;

    $token = $_GET['token'] ?? '';
    $sig   = $_GET['sig'] ?? '';

    if (!$token || !$sig) {
        http_response_code(403);
        die('Missing authentication token.');
    }

    /**
     * Verify signature
     */
    $expectedSig = hash_hmac('sha256', $token, $HOMEBASE_AUTH_SECRET);
    if (!hash_equals($expectedSig, $sig)) {
        http_response_code(403);
        die('Invalid authentication signature.');
    }

    /**
     * Decode token payload
     */
    $payload = json_decode(base64_decode($token), true);
    if (!$payload || !is_array($payload)) {
        http_response_code(403);
        die('Invalid authentication payload.');
    }

    /**
     * Expiration check
     */
    if (empty($payload['exp']) || time() > $payload['exp']) {
        http_response_code(403);
        die('Authentication token expired.');
    }

    /**
     * Account enforcement
     */
    $accountType = strtolower($payload['account_type'] ?? '');
    if (!in_array($accountType, ['linetech', 'lineops'], true)) {
        http_response_code(403);
        die('Account not authorized for Homebase.');
    }

    /**
     * 🔐 CRITICAL: Regenerate session after auth
     */
    session_regenerate_id(true);

    /**
     * Establish Homebase session
     */
    $_SESSION['user'] = [
        'email'         => $payload['email'],
        'account_type'  => $accountType,
        'authenticated' => true,
        'login_time'    => time(),
    ];

    /**
     * Redirect into Homebase
     */
    header('Location: /');
    exit;
}