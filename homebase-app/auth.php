<?php

function get_homebase_device_id(): string {
  return trim(file_get_contents('/etc/homebase/device_id'));
}

function verify_device_id(string $incoming): bool {
  return hash_equals(get_homebase_device_id(), $incoming);
}

function require_login(): void {
  if (empty($_SESSION['user'])) {
    header('Location: /login.php');
    exit;
  }
}