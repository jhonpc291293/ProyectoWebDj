<?php
/**
 * VIP PAITA MIX · Fase 3 de la migración: usuarios, login y contraseñas.
 * Reemplaza a Supabase Auth, que hacía todo esto (y el envío de correos de
 * recuperación) por su cuenta.
 *
 * Dos grupos de funciones:
 *  - "sin sesión": la lógica de verdad (crear cuenta, verificar contraseña,
 *    tokens de recuperación). Son las que de verdad hay que probar bien.
 *  - "con sesión": conectan esa lógica con $_SESSION de PHP. Livianas a
 *    propósito -- la Fase 5 las va a llamar desde las páginas reales.
 *
 * NOTA para cuando esto viva en un hosting real: hay que configurar la
 * sesión con cookies "secure" (solo HTTPS) y "httponly", y el envío de
 * correo de recuperación necesita un SMTP configurado en el hosting --
 * aquí solo se genera el token, no se manda el correo todavía.
 */

declare(strict_types=1);
require_once __DIR__ . '/funciones.php';

final class CredencialesInvalidas extends Exception {}
final class CorreoYaRegistrado extends Exception {}
final class TokenInvalido extends Exception {}

// ---------------------------------------------------------------------------
// Crear una cuenta nueva. El primer usuario de todo el sistema queda admin
// (antes lo hacía el trigger nuevo_perfil() de Supabase); el resto, member.
// ---------------------------------------------------------------------------
function registrar_usuario(PDO $pdo, string $email, string $password, string $nombre, string $telefono = ''): string {
  $email = strtolower(trim($email));
  if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
    throw new InvalidArgumentException('Correo no válido');
  }
  if (strlen($password) < 6) {
    throw new InvalidArgumentException('La contraseña necesita al menos 6 caracteres');
  }

  $st = $pdo->prepare('SELECT 1 FROM usuarios WHERE email = ?');
  $st->execute([$email]);
  if ($st->fetchColumn()) {
    throw new CorreoYaRegistrado("Ya existe una cuenta con el correo $email");
  }

  $total = (int) $pdo->query('SELECT COUNT(*) FROM usuarios')->fetchColumn();
  $rol = $total === 0 ? 'admin' : 'member';

  $id = uuid_v4();
  $st = $pdo->prepare(
    'INSERT INTO usuarios (id, email, password_hash, nombre, telefono, rol) VALUES (?, ?, ?, ?, ?, ?)'
  );
  $st->execute([$id, $email, password_hash($password, PASSWORD_DEFAULT), $nombre, $telefono, $rol]);
  return $id;
}

// ---------------------------------------------------------------------------
// Verifica correo + contraseña. Devuelve el usuario (sin el hash) o null.
// ---------------------------------------------------------------------------
function verificar_credenciales(PDO $pdo, string $email, string $password): ?array {
  $st = $pdo->prepare('SELECT * FROM usuarios WHERE email = ?');
  $st->execute([strtolower(trim($email))]);
  $u = $st->fetch(PDO::FETCH_ASSOC);
  if (!$u || !password_verify($password, $u['password_hash'])) {
    return null;
  }
  unset($u['password_hash'], $u['reset_token']);
  return $u;
}

// ---------------------------------------------------------------------------
// Recuperar contraseña: genera un token, válido 1 hora. Se guarda en la base
// de datos un HASH del token (sha256), nunca el token en texto plano -- así,
// si alguien llegara a leer la base de datos, no puede usar esos tokens.
// El token de verdad (sin hashear) es lo único que se manda por correo
// (ese envío de correo lo conecta la Fase 5, cuando haya SMTP configurado).
// ---------------------------------------------------------------------------
function solicitar_restablecer(PDO $pdo, string $email): ?string {
  $st = $pdo->prepare('SELECT id FROM usuarios WHERE email = ?');
  $st->execute([strtolower(trim($email))]);
  $userId = $st->fetchColumn();
  if (!$userId) return null; // no se revela si el correo existe o no

  $token = bin2hex(random_bytes(32));
  $hash = hash('sha256', $token);
  $expira = (new DateTime('+1 hour'))->format('Y-m-d H:i:s');

  $st = $pdo->prepare('UPDATE usuarios SET reset_token = ?, reset_expira = ? WHERE id = ?');
  $st->execute([$hash, $expira, $userId]);

  return $token;
}

function restablecer_con_token(PDO $pdo, string $token, string $nuevaPassword): void {
  if (strlen($nuevaPassword) < 6) {
    throw new InvalidArgumentException('La contraseña necesita al menos 6 caracteres');
  }
  $hash = hash('sha256', $token);
  $st = $pdo->prepare('SELECT id FROM usuarios WHERE reset_token = ? AND reset_expira >= NOW()');
  $st->execute([$hash]);
  $userId = $st->fetchColumn();
  if (!$userId) {
    throw new TokenInvalido('El enlace ya venció o no es válido. Pide uno nuevo.');
  }
  $st = $pdo->prepare(
    'UPDATE usuarios SET password_hash = ?, reset_token = NULL, reset_expira = NULL WHERE id = ?'
  );
  $st->execute([password_hash($nuevaPassword, PASSWORD_DEFAULT), $userId]);
}

// ---------------------------------------------------------------------------
// El admin crea una cuenta directamente (editor o miembro), con una
// contraseña temporal que él define -- igual que la función "crear-usuario"
// de Supabase. No pasa por el flujo de "primer usuario = admin".
// ---------------------------------------------------------------------------
function admin_crear_usuario(PDO $pdo, string $adminId, string $email, string $password, string $nombre, string $rol): string {
  if (!es_admin($pdo, $adminId)) {
    throw new AccesoDenegado('Solo el administrador puede crear cuentas');
  }
  if (!in_array($rol, ['admin', 'editor', 'member'], true)) {
    throw new InvalidArgumentException("Rol no válido: $rol");
  }
  $email = strtolower(trim($email));
  if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
    throw new InvalidArgumentException('Correo no válido');
  }
  if (strlen($password) < 6) {
    throw new InvalidArgumentException('La contraseña necesita al menos 6 caracteres');
  }
  $st = $pdo->prepare('SELECT 1 FROM usuarios WHERE email = ?');
  $st->execute([$email]);
  if ($st->fetchColumn()) {
    throw new CorreoYaRegistrado("Ya existe una cuenta con el correo $email");
  }

  $id = uuid_v4();
  $st = $pdo->prepare(
    'INSERT INTO usuarios (id, email, password_hash, nombre, rol) VALUES (?, ?, ?, ?, ?)'
  );
  $st->execute([$id, $email, password_hash($password, PASSWORD_DEFAULT), $nombre, $rol]);
  return $id;
}

// el admin resetea la clave de otra cuenta directamente, sin correo
function admin_resetear_password(PDO $pdo, string $adminId, string $targetUserId, string $nuevaPassword): void {
  if (!es_admin($pdo, $adminId)) {
    throw new AccesoDenegado('Solo el administrador puede restablecer contraseñas');
  }
  if (strlen($nuevaPassword) < 6) {
    throw new InvalidArgumentException('La contraseña necesita al menos 6 caracteres');
  }
  $st = $pdo->prepare('UPDATE usuarios SET password_hash = ?, reset_token = NULL, reset_expira = NULL WHERE id = ?');
  $st->execute([password_hash($nuevaPassword, PASSWORD_DEFAULT), $targetUserId]);
}

function uuid_v4(): string {
  $d = random_bytes(16);
  $d[6] = chr((ord($d[6]) & 0x0f) | 0x40);
  $d[8] = chr((ord($d[8]) & 0x3f) | 0x80);
  return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($d), 4));
}

// ---------------------------------------------------------------------------
// Puente con la sesión de PHP (lo usará la Fase 5 desde las páginas reales)
// ---------------------------------------------------------------------------
function iniciar_sesion(PDO $pdo, string $email, string $password): array {
  $u = verificar_credenciales($pdo, $email, $password);
  if (!$u) throw new CredencialesInvalidas('Correo o contraseña incorrectos');
  session_regenerate_id(true);
  $_SESSION['user_id'] = $u['id'];
  return $u;
}

function cerrar_sesion(): void {
  $_SESSION = [];
  session_destroy();
}

function usuario_actual(): ?string {
  return $_SESSION['user_id'] ?? null;
}

function requiere_sesion(): string {
  $id = usuario_actual();
  if (!$id) throw new AccesoDenegado('Necesitas iniciar sesión');
  return $id;
}

function requiere_admin(PDO $pdo): string {
  $id = requiere_sesion();
  if (!es_admin($pdo, $id)) throw new AccesoDenegado('Necesitas ser administrador');
  return $id;
}
