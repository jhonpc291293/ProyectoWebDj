<?php
declare(strict_types=1);
require __DIR__ . '/funciones.php';

$pdo = new PDO('mysql:host=vpm-mysql-test;dbname=vip_paita_mix;charset=utf8mb4', 'root', 'test1234', [
  PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
  PDO::MYSQL_ATTR_INIT_COMMAND => "SET time_zone = '-05:00'", // igual que web/config.php
]);

function uuid(): string {
  $d = random_bytes(16);
  $d[6] = chr((ord($d[6]) & 0x0f) | 0x40);
  $d[8] = chr((ord($d[8]) & 0x3f) | 0x80);
  return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($d), 4));
}

$fallos = 0;
function verificar(string $titulo, bool $condicion): void {
  global $fallos;
  echo ($condicion ? "OK   " : "FALLO") . " - $titulo\n";
  if (!$condicion) $fallos++;
}

// --- datos de prueba -------------------------------------------------------
$adminId = uuid();
$pdo->prepare('INSERT INTO usuarios (id, email, password_hash, nombre, rol) VALUES (?, ?, ?, ?, ?)')
  ->execute([$adminId, 'admin@test.com', 'x', 'Admin', 'admin']);

$memberAId = uuid(); // tiene plan Mensual activo
$pdo->prepare('INSERT INTO usuarios (id, email, password_hash, nombre, rol) VALUES (?, ?, ?, ?, ?)')
  ->execute([$memberAId, 'membera@test.com', 'x', 'Miembro A', 'member']);

$memberBId = uuid(); // sin membresía
$pdo->prepare('INSERT INTO usuarios (id, email, password_hash, nombre, rol) VALUES (?, ?, ?, ?, ?)')
  ->execute([$memberBId, 'memberb@test.com', 'x', 'Miembro B', 'member']);

$editorId = uuid(); // editor sin membresía propia
$pdo->prepare('INSERT INTO usuarios (id, email, password_hash, nombre, rol) VALUES (?, ?, ?, ?, ?)')
  ->execute([$editorId, 'editor@test.com', 'x', 'Editor', 'editor']);

[$planMensualId, $planAnualId] = $pdo->query("SELECT id FROM planes WHERE nombre IN ('Mensual','Anual') ORDER BY FIELD(nombre,'Mensual','Anual')")
  ->fetchAll(PDO::FETCH_COLUMN);

// Miembro A: plan Mensual activo, vence en 10 días
$membMensualId = uuid();
$pdo->prepare("INSERT INTO memberships (id, user_id, plan_id, estado, inicio, fin) VALUES (?, ?, ?, 'activa', CURDATE(), DATE_ADD(CURDATE(), INTERVAL 10 DAY))")
  ->execute([$membMensualId, $memberAId, $planMensualId]);

// tracks: uno gratis, uno normal (requiere cualquier membresía), uno premium (requiere plan Anual o superior)
$trackGratisId = uuid();
$pdo->prepare("INSERT INTO tracks (id, titulo, editor, gratis, visible) VALUES (?, 'Track gratis', 'DJ Ronald', 1, 1)")
  ->execute([$trackGratisId]);

$trackNormalId = uuid();
$pdo->prepare("INSERT INTO tracks (id, titulo, editor, visible) VALUES (?, 'Track normal', 'DJ Ronald', 1)")
  ->execute([$trackNormalId]);
$pdo->prepare("INSERT INTO track_files (track_id, ruta) VALUES (?, '/privado/normal.mp3')")->execute([$trackNormalId]);

$trackPremiumId = uuid();
$pdo->prepare("INSERT INTO tracks (id, titulo, editor, visible, plan_minimo_id) VALUES (?, 'Track premium', 'DJ Ronald', 1, ?)")
  ->execute([$trackPremiumId, $planAnualId]);
$pdo->prepare("INSERT INTO track_files (track_id, ruta) VALUES (?, '/privado/premium.mp3')")->execute([$trackPremiumId]);

echo "=== Roles ===\n";
verificar('admin es admin', es_admin($pdo, $adminId) === true);
verificar('miembro A no es admin', es_admin($pdo, $memberAId) === false);
verificar('editor es staff', es_staff($pdo, $editorId) === true);
verificar('miembro B no es staff', es_staff($pdo, $memberBId) === false);

echo "\n=== Membresía activa ===\n";
verificar('admin siempre tiene membresía activa (bypass)', membresia_activa($pdo, $adminId) === true);
verificar('miembro A tiene membresía activa', membresia_activa($pdo, $memberAId) === true);
verificar('miembro B NO tiene membresía activa', membresia_activa($pdo, $memberBId) === false);
verificar('editor SIN membresía propia no tiene membresía activa (no hay vía libre por rol)', membresia_activa($pdo, $editorId) === false);

echo "\n=== Descargas según plan (puede_descargar_track) ===\n";
verificar('cualquiera descarga el track gratis', puede_descargar_track($pdo, $memberBId, $trackGratisId) === true);
verificar('miembro A (Mensual) descarga el track normal', puede_descargar_track($pdo, $memberAId, $trackNormalId) === true);
verificar('miembro B (sin plan) NO descarga el track normal', puede_descargar_track($pdo, $memberBId, $trackNormalId) === false);
verificar('miembro A (Mensual) NO descarga el premium (pide Anual)', puede_descargar_track($pdo, $memberAId, $trackPremiumId) === false);
verificar('editor sin membresía NO descarga el normal (no hay vía libre por rol)', puede_descargar_track($pdo, $editorId, $trackNormalId) === false);
verificar('admin descarga cualquier cosa', puede_descargar_track($pdo, $adminId, $trackPremiumId) === true);

echo "\n=== Compra suelta desbloquea el premium ===\n";
$compraId = uuid();
$pdo->prepare("INSERT INTO compras (id, user_id, estado) VALUES (?, ?, 'aprobada')")->execute([$compraId, $memberAId]);
$pdo->prepare("INSERT INTO compra_tracks (compra_id, track_id, precio) VALUES (?, ?, 5)")->execute([$compraId, $trackPremiumId]);
verificar('tras comprarlo suelto, miembro A SÍ descarga el premium', puede_descargar_track($pdo, $memberAId, $trackPremiumId) === true);
verificar('compro_track lo confirma', compro_track($pdo, $memberAId, $trackPremiumId) === true);
verificar('mis_compras incluye el premium', in_array($trackPremiumId, mis_compras($pdo, $memberAId), true));

echo "\n=== solicitar_descarga: flujo real + límite diario ===\n";
$ruta = solicitar_descarga($pdo, $memberAId, $trackNormalId);
verificar('devuelve la ruta correcta', $ruta === '/privado/normal.mp3');

// le ponemos límite diario de 1 descarga al plan Mensual y probamos que la 2da falle
$pdo->prepare('UPDATE planes SET limite_diario = 1 WHERE id = ?')->execute([$planMensualId]);
$trackNormal2Id = uuid();
$pdo->prepare("INSERT INTO tracks (id, titulo, editor, visible) VALUES (?, 'Track normal 2', 'DJ Ronald', 1)")->execute([$trackNormal2Id]);
$pdo->prepare("INSERT INTO track_files (track_id, ruta) VALUES (?, '/privado/normal2.mp3')")->execute([$trackNormal2Id]);
try {
  solicitar_descarga($pdo, $memberAId, $trackNormal2Id);
  verificar('la 2da descarga del día debía fallar por límite diario', false);
} catch (RuntimeException $e) {
  verificar('la 2da descarga del día falla por límite diario (' . $e->getMessage() . ')', true);
}
// la compra suelta NO debe gastar el límite diario
$ruta2 = solicitar_descarga($pdo, $memberAId, $trackPremiumId);
verificar('una canción comprada suelta no gasta el límite diario', $ruta2 === '/privado/premium.mp3');

echo "\n=== aprobar_membresia sin permiso ===\n";
try {
  aprobar_membresia($pdo, $memberAId, $membMensualId);
  verificar('un miembro NO debería poder aprobar membresías', false);
} catch (AccesoDenegado $e) {
  verificar('un miembro no puede aprobar membresías (bloqueado correctamente)', true);
}

echo "\n=== aprobar_membresia extiende desde el fin vigente, no desde hoy ===\n";
$stAntes = $pdo->prepare('SELECT fin FROM memberships WHERE id = ?');
$stAntes->execute([$membMensualId]);
$antes = $stAntes->fetchColumn();
$m = aprobar_membresia($pdo, $adminId, $membMensualId);
verificar("el fin se extendió 30 días desde el fin anterior ($antes -> {$m['fin']})",
  (new DateTime($m['fin']))->diff(new DateTime($antes))->days === 30);

echo "\n=== cambiar_rol ===\n";
try {
  cambiar_rol($pdo, $memberBId, $memberAId, 'admin');
  verificar('un miembro NO debería poder cambiar roles', false);
} catch (AccesoDenegado $e) {
  verificar('un miembro no puede cambiar roles (bloqueado correctamente)', true);
}
cambiar_rol($pdo, $adminId, $memberBId, 'editor');
verificar('el admin sí puede cambiar el rol de alguien', mi_rol($pdo, $memberBId) === 'editor');

echo "\n=== mi_membresia ===\n";
$resumen = mi_membresia($pdo, $memberAId);
verificar('mi_membresia reporta estado activa', $resumen['estado'] === 'activa');
verificar('mi_membresia reporta plan_precio correcto', (float) $resumen['plan_precio'] === 40.0);
$resumenVacio = mi_membresia($pdo, $memberBId);
verificar('mi_membresia de quien nunca tuvo nada es "ninguna"', $resumenVacio['estado'] === 'ninguna');

echo "\n=== vencer_membresias ===\n";
$membVencidaId = uuid();
$pdo->prepare("INSERT INTO memberships (id, user_id, plan_id, estado, inicio, fin) VALUES (?, ?, ?, 'activa', DATE_SUB(CURDATE(), INTERVAL 40 DAY), DATE_SUB(CURDATE(), INTERVAL 10 DAY))")
  ->execute([uuid(), $memberBId, $planMensualId]);
$n = vencer_membresias($pdo, $adminId);
verificar("vencer_membresias actualizó al menos 1 fila (actualizó $n)", $n >= 1);

echo "\n" . ($fallos === 0 ? "TODO OK ({$fallos} fallos)\n" : "HAY {$fallos} FALLO(S)\n");
exit($fallos === 0 ? 0 : 1);
