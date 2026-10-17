<?php
declare(strict_types=1);
session_start();
require __DIR__ . '/../auth.php';
require __DIR__ . '/../archivos.php';
require __DIR__ . '/config.php';

try {
  $userId = requiere_sesion();
  $trackId = $_GET['track'] ?? '';
  if ($trackId === '') throw new InvalidArgumentException('Falta el track');

  // esto valida permiso + plan mínimo + límite diario, y registra la descarga
  $ruta = solicitar_descarga($pdo, $userId, $trackId);
  $fisica = ruta_fisica_privada($ruta);
  if (!is_file($fisica)) throw new RuntimeException('El archivo no está disponible en el servidor');

  header('Content-Type: application/octet-stream');
  header('Content-Disposition: attachment; filename="' . basename($fisica) . '"');
  header('Content-Length: ' . filesize($fisica));
  readfile($fisica);
  exit;
} catch (AccesoDenegado $e) {
  http_response_code(403); echo 'ERROR:' . $e->getMessage();
} catch (Throwable $e) {
  http_response_code(400); echo 'ERROR:' . $e->getMessage();
}
