<?php
session_start();

$data = json_decode(file_get_contents("php://input"), true);

if (!$data || !isset($data['account_type'])) {
	http_response_code(400);
	exit;
}

$_SESSION['user'] = [
	'id'           => $data['id'] ?? null,
	'email'        => $data['email'],
	'account_type' => $data['account_type']
];

echo json_encode(['ok' => true]);