<?php
declare(strict_types=1);
require __DIR__ . '/auth.php';
require __DIR__ . '/archivos.php';

$pdo = new PDO('mysql:host=vpm-mysql-test;dbname=vip_paita_mix;charset=utf8mb4', 'root', 'test1234', [
  PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
  PDO::MYSQL_ATTR_INIT_COMMAND => "SET time_zone = '-05:00'", // igual que web/config.php
]);

$adminId = registrar_usuario($pdo, 'admin@test.com', 'claveadmin', 'Admin');
$memberAId = registrar_usuario($pdo, 'membera@test.com', 'clavea123', 'Miembro A');
$memberBId = registrar_usuario($pdo, 'memberb@test.com', 'claveb123', 'Miembro B');

$planId = $pdo->query("SELECT id FROM planes WHERE nombre = 'Mensual'")->fetchColumn();
$membId = bin2hex(random_bytes(16));
$pdo->prepare(
  "INSERT INTO memberships (id, user_id, plan_id, estado, inicio, fin, comprobante)
   VALUES (?, ?, ?, 'activa', CURDATE(), DATE_ADD(CURDATE(), INTERVAL 10 DAY), 'comprobantes/pago-membera.jpg')"
)->execute([$membId, $memberAId, $planId]);

$trackId = bin2hex(random_bytes(16));
$pdo->prepare("INSERT INTO tracks (id, titulo, editor, visible) VALUES (?, 'Track de prueba', 'DJ Ronald', 1)")
  ->execute([$trackId]);

// archivo físico real para la descarga + el comprobante, en la carpeta privada
if (!is_dir(RUTA_PRIVADA . '/descargas')) mkdir(RUTA_PRIVADA . '/descargas', 0755, true);
if (!is_dir(RUTA_PRIVADA . '/comprobantes')) mkdir(RUTA_PRIVADA . '/comprobantes', 0755, true);
file_put_contents(RUTA_PRIVADA . '/descargas/cancion-prueba.mp3', 'contenido falso de audio');
file_put_contents(RUTA_PRIVADA . '/comprobantes/pago-membera.jpg', 'contenido falso de imagen');

$pdo->prepare("INSERT INTO track_files (track_id, ruta) VALUES (?, 'descargas/cancion-prueba.mp3')")
  ->execute([$trackId]);

echo "admin=$adminId\n";
echo "memberA=$memberAId\n";
echo "memberB=$memberBId\n";
echo "track=$trackId\n";
