<?php
session_start();
require_once __DIR__ . '/auth.php';
require_login();
?>
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Homebase</title>
</head>
<body>

<h1>Homebase</h1>
<p>Logged in as <strong><?= htmlspecialchars($_SESSION['user']['email']) ?></strong></p>

<ul>
    <li><a href="/feeds/combined.php">Combined Feed</a></li>
    <li><a href="/feeds/dump1090-aircraft.php">ADS-B (1090)</a></li>
    <li><a href="/feeds/dump978-latest.php">UAT (978)</a></li>
</ul>

<a href="/logout.php">Sign out</a>

</body>
</html>