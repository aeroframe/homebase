<?php
session_start();

// trust Aeroframe session
if (empty($_SESSION['email'])) {
    header('Location: /login.php');
    exit;
}
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