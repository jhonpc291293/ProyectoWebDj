<?php
declare(strict_types=1);
session_start();
require __DIR__ . '/auth.php';

$pdo = new PDO('mysql:host=vpm-mysql-test;dbname=vip_paita_mix;charset=utf8mb4', 'root', 'test1234', [
  PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
]);

$fallos = 0;
function verificar(string $titulo, bool $condicion): void {
  global $fallos;
  echo ($condicion ? "OK   " : "FALLO") . " - $titulo\n";
  if (!$condicion) $fallos++;
}

echo "=== Registro ===\n";
$adminId = registrar_usuario($pdo, 'Admin@Test.com', 'claveadmin', 'Ronald');
verificar('el primer usuario registrado queda admin', mi_rol($pdo, $adminId) === 'admin');

$memberId = registrar_usuario($pdo, 'miembro@test.com', 'clave123', 'Un Miembro');
verificar('el segundo usuario registrado queda member', mi_rol($pdo, $memberId) === 'member');

try {
  registrar_usuario($pdo, 'admin@test.com', 'otraclave', 'Otro'); // mismo correo, distintas mayúsculas
  verificar('no debería permitir correo repetido', false);
} catch (CorreoYaRegistrado $e) {
  verificar('rechaza correo repetido sin importar mayúsculas (' . $e->getMessage() . ')', true);
}

try {
  registrar_usuario($pdo, 'no-es-correo', 'clave123', 'X');
  verificar('no debería permitir un correo mal formado', false);
} catch (InvalidArgumentException $e) {
  verificar('rechaza correo mal formado', true);
}

try {
  registrar_usuario($pdo, 'nuevo@test.com', '123', 'X');
  verificar('no debería permitir contraseña corta', false);
} catch (InvalidArgumentException $e) {
  verificar('rechaza contraseña de menos de 6 caracteres', true);
}

echo "\n=== Verificar credenciales ===\n";
$u = verificar_credenciales($pdo, 'admin@test.com', 'claveadmin');
verificar('login correcto devuelve el usuario', $u !== null && $u['id'] === $adminId);
verificar('el usuario devuelto NUNCA trae el password_hash', !isset($u['password_hash']));

$u2 = verificar_credenciales($pdo, 'admin@test.com', 'clave-incorrecta');
verificar('contraseña incorrecta devuelve null', $u2 === null);

$u3 = verificar_credenciales($pdo, 'noexiste@test.com', 'cualquiera');
verificar('correo inexistente devuelve null (sin revelar que no existe)', $u3 === null);

echo "\n=== Recuperar contraseña ===\n";
$token = solicitar_restablecer($pdo, 'miembro@test.com');
verificar('genera un token para un correo existente', is_string($token) && strlen($token) === 64);

$tokenInexistente = solicitar_restablecer($pdo, 'fantasma@test.com');
verificar('no genera token (ni error) para un correo que no existe', $tokenInexistente === null);

restablecer_con_token($pdo, $token, 'clavenueva123');
verificar('con la clave nueva sí entra', verificar_credenciales($pdo, 'miembro@test.com', 'clavenueva123') !== null);
verificar('con la clave vieja ya NO entra', verificar_credenciales($pdo, 'miembro@test.com', 'clave123') === null);

try {
  restablecer_con_token($pdo, $token, 'otraclave123');
  verificar('el mismo token no debería poder reusarse', false);
} catch (TokenInvalido $e) {
  verificar('el token ya usado queda invalidado (' . $e->getMessage() . ')', true);
}

try {
  restablecer_con_token($pdo, 'token-que-nunca-existio', 'clave123456');
  verificar('un token inventado no debería funcionar', false);
} catch (TokenInvalido $e) {
  verificar('rechaza un token inventado', true);
}

echo "\n=== El admin crea cuentas directamente ===\n";
try {
  admin_crear_usuario($pdo, $memberId, 'editor1@test.com', 'clave123', 'DJ Nuevo', 'editor');
  verificar('un miembro NO debería poder crear cuentas', false);
} catch (AccesoDenegado $e) {
  verificar('bloquea a quien no es admin', true);
}

$editorId = admin_crear_usuario($pdo, $adminId, 'editor1@test.com', 'clavetemp1', 'DJ Nuevo', 'editor');
verificar('el admin crea la cuenta con el rol elegido', mi_rol($pdo, $editorId) === 'editor');
verificar('la cuenta recién creada puede loguearse ya mismo', verificar_credenciales($pdo, 'editor1@test.com', 'clavetemp1') !== null);

echo "\n=== El admin resetea una contraseña directamente ===\n";
try {
  admin_resetear_password($pdo, $editorId, $memberId, 'clavequesea');
  verificar('un editor NO debería poder resetear contraseñas de otros', false);
} catch (AccesoDenegado $e) {
  verificar('bloquea a quien no es admin', true);
}
admin_resetear_password($pdo, $adminId, $editorId, 'clavenuevadeladmin');
verificar('tras el reset del admin, la cuenta entra con la clave nueva', verificar_credenciales($pdo, 'editor1@test.com', 'clavenuevadeladmin') !== null);

echo "\n=== Sesión ===\n";
try {
  requiere_sesion();
  verificar('sin sesión iniciada debería fallar', false);
} catch (AccesoDenegado $e) {
  verificar('requiere_sesion bloquea sin login', true);
}

iniciar_sesion($pdo, 'admin@test.com', 'claveadmin');
verificar('tras iniciar sesión, usuario_actual devuelve el id correcto', usuario_actual() === $adminId);
verificar('requiere_admin pasa para el admin logueado', requiere_admin($pdo) === $adminId);

cerrar_sesion();
verificar('tras cerrar sesión, usuario_actual vuelve a null', usuario_actual() === null);

iniciar_sesion($pdo, 'miembro@test.com', 'clavenueva123');
try {
  requiere_admin($pdo);
  verificar('requiere_admin debería bloquear a un miembro', false);
} catch (AccesoDenegado $e) {
  verificar('requiere_admin bloquea a quien no es admin', true);
}

try {
  iniciar_sesion($pdo, 'admin@test.com', 'clave-mala');
  verificar('login con clave incorrecta debería fallar', false);
} catch (CredencialesInvalidas $e) {
  verificar('iniciar_sesion rechaza credenciales incorrectas', true);
}

echo "\n" . ($fallos === 0 ? "TODO OK ({$fallos} fallos)\n" : "HAY {$fallos} FALLO(S)\n");
exit($fallos === 0 ? 0 : 1);
