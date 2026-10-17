<?php
declare(strict_types=1);
session_start();
require __DIR__ . '/../auth.php';
require __DIR__ . '/config.php';

try {
  $u = iniciar_sesion($pdo, $_POST['email'] ?? '', $_POST['password'] ?? '');
  echo 'OK:' . $u['id'];
} catch (Throwable $e) {
  http_response_code(401);
  echo 'ERROR:' . $e->getMessage();
}
