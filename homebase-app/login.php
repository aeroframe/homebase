<?php
$return = 'http://' . $_SERVER['HTTP_HOST'] . '/';

header('Location: https://aerofra.me/auth/?return=' . urlencode($return));
exit;
?>