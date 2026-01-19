<?php
session_start();

/**
 * Require authenticated Homebase session
 */
if (
    empty($_SESSION['user']) ||
    empty($_SESSION['user']['authenticated']) ||
    $_SESSION['user']['authenticated'] !== true
) {
    header('Location: /login.php');
    exit;
}

$user = $_SESSION['user'];
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Homebase</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
</head>
<body>

<h1>Homebase</h1>

<p>
    Logged in as
    <strong><?= htmlspecialchars($user['email'], ENT_QUOTES) ?></strong>
    (<?= htmlspecialchars($user['account_type']) ?>)
</p>

<ul>
    <li><a href="/feeds/combined.php">Combined Feed</a></li>
    <li><a href="/feeds/dump1090-aircraft.php">ADS-B (1090)</a></li>
    <li><a href="/feeds/dump978-latest.php">UAT (978)</a></li>
</ul>

<p>
    <a href="/logout.php">Sign out</a>
</p>

</body>
</html>