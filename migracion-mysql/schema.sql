-- ============================================================================
--  VIP PAITA MIX · Esquema MySQL (Fase 1 de la migración fuera de Supabase)
--
--  Esto reemplaza supabase-schema.sql, pero OJO: ahí la seguridad la aplicaba
--  Postgres solo (RLS) con auth.uid() tomado de la sesión. MySQL no tiene nada
--  parecido: cada tabla trae un comentario "SEGURIDAD EN PHP" explicando qué
--  verificación tiene que hacer el código de PHP antes de tocar esa tabla,
--  porque la base de datos ya no lo va a impedir sola.
--
--  Pensado para MySQL 8.0+ / MariaDB 10.5+ (lo que trae cualquier cPanel
--  moderno). Usa CHAR(36) para IDs tipo UUID -- el PHP los genera (Fase 3),
--  MySQL no tiene gen_random_uuid().
-- ============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- ---------------------------------------------------------------------------
-- 1. USUARIOS (reemplaza a la vez auth.users + profiles de Supabase)
--    admin  = Ronald: todo el catálogo, miembros, pagos, planes
--    editor = los DJs del crew: solo sus propios tracks
--    member = suscriptores: descargan si su membresía está vigente
--
--    SEGURIDAD EN PHP:
--    - "ve su perfil" / "edita su perfil": el PHP solo deja leer/editar la
--      fila cuyo id sea el del usuario en sesión (o cualquiera, si es admin).
--    - "rol" NUNCA se actualiza desde un formulario normal: solo una función
--      de PHP exclusiva para admin (equivalente a cambiar_rol()) la toca.
--    - El primer usuario que se registre en todo el sistema se vuelve admin
--      automáticamente (antes lo hacía el trigger nuevo_perfil()); en PHP:
--      "if (count(usuarios) == 0) rol = 'admin' else rol = 'member'".
-- ---------------------------------------------------------------------------
CREATE TABLE usuarios (
  id            CHAR(36)     PRIMARY KEY,
  email         VARCHAR(255) NOT NULL UNIQUE,
  password_hash VARCHAR(255) NOT NULL,          -- PHP: password_hash(), nunca texto plano
  nombre        VARCHAR(255) NOT NULL DEFAULT '',
  alias         VARCHAR(255) NOT NULL DEFAULT '',   -- nombre artístico del DJ
  rol           ENUM('admin','editor','member') NOT NULL DEFAULT 'member',
  telefono      VARCHAR(50)  NOT NULL DEFAULT '',
  avatar        VARCHAR(500) NOT NULL DEFAULT '',
  reset_token   VARCHAR(255) DEFAULT NULL,       -- recuperar contraseña (Fase 3)
  reset_expira  DATETIME     DEFAULT NULL,
  creado        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 2. CONTENIDO DE LA MARCA (una sola fila, igual que en Supabase)
--
--    SEGURIDAD EN PHP: cualquiera lee (es la web pública); solo admin escribe.
-- ---------------------------------------------------------------------------
CREATE TABLE settings (
  id          TINYINT UNSIGNED PRIMARY KEY DEFAULT 1,
  marca       VARCHAR(255) NOT NULL DEFAULT 'VIP PAITA MIX',
  creador     VARCHAR(255) NOT NULL DEFAULT 'Ronald Moscol',
  desde       SMALLINT     NOT NULL DEFAULT 2016,
  ciudad      VARCHAR(255) NOT NULL DEFAULT 'Paita, Piura · Perú',
  claim       TEXT,
  hero_l1     VARCHAR(100) NOT NULL DEFAULT 'EDITS QUE',
  hero_l2     VARCHAR(100) NOT NULL DEFAULT 'LLENAN',
  hero_l3     VARCHAR(100) NOT NULL DEFAULT 'LA PISTA',
  logo_url    VARCHAR(500) NOT NULL DEFAULT '',
  hero_img    VARCHAR(500) NOT NULL DEFAULT '',
  hero_video_fondo VARCHAR(500) NOT NULL DEFAULT '',
  whatsapp    VARCHAR(30)  NOT NULL DEFAULT '51999999999',
  email       VARCHAR(255) NOT NULL DEFAULT 'contacto@vippaitamix.com',
  moneda      VARCHAR(10)  NOT NULL DEFAULT 'S/',
  yape_nombre VARCHAR(255) NOT NULL DEFAULT 'Ronald Moscol',
  yape_numero VARCHAR(30)  NOT NULL DEFAULT '999 999 999',
  yape_qr     VARCHAR(500) NOT NULL DEFAULT '',
  pago_nota   TEXT,
  frases      JSON,                              -- antes jsonb
  hitos       JSON,                              -- antes jsonb
  redes       JSON,                              -- antes jsonb
  tema        ENUM('normal','halloween','navidad','ano-nuevo') NOT NULL DEFAULT 'normal',
  color_fondo      VARCHAR(20) NOT NULL DEFAULT '',
  color_tarjetas   VARCHAR(20) NOT NULL DEFAULT '',
  color_encabezado VARCHAR(20) NOT NULL DEFAULT '',
  color_piepagina  VARCHAR(20) NOT NULL DEFAULT '',
  color_texto      VARCHAR(20) NOT NULL DEFAULT '',
  color_acento     VARCHAR(20) NOT NULL DEFAULT '',
  fuente_titulos   VARCHAR(100) NOT NULL DEFAULT '',
  fuente_texto     VARCHAR(100) NOT NULL DEFAULT '',
  video_activo     BOOLEAN NOT NULL DEFAULT FALSE,
  video_url        VARCHAR(500) NOT NULL DEFAULT '',
  video_archivo    VARCHAR(500) NOT NULL DEFAULT '',
  audio_destacado_titulo  VARCHAR(255) NOT NULL DEFAULT '',
  audio_destacado_archivo VARCHAR(500) NOT NULL DEFAULT '',
  actualizado DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO settings (id) VALUES (1);

-- ---------------------------------------------------------------------------
-- 3. EL CREW que se muestra en la web (independiente de las cuentas de acceso)
--
--    SEGURIDAD EN PHP: cualquiera lee lo visible=1; solo admin escribe.
-- ---------------------------------------------------------------------------
CREATE TABLE crew (
  id      CHAR(36)     PRIMARY KEY,
  orden   INT          NOT NULL DEFAULT 0,
  alias   VARCHAR(255) NOT NULL,
  nombre  VARCHAR(255) NOT NULL DEFAULT '',
  cargo   VARCHAR(255) NOT NULL DEFAULT 'DJ / Editor',
  email   VARCHAR(255) NOT NULL DEFAULT '',
  bio     TEXT,
  foto    VARCHAR(500) NOT NULL DEFAULT '',
  ig      VARCHAR(255) NOT NULL DEFAULT '',
  visible BOOLEAN      NOT NULL DEFAULT TRUE,
  creado  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 4. COMUNICADOS del equipo
--
--    SEGURIDAD EN PHP:
--    - lee: cualquier admin/editor logueado (no es público).
--    - crea: cualquier editor, pero autor_id = su propio id.
--    - edita/borra: el editor solo el suyo (autor_id = su id); admin, todos.
-- ---------------------------------------------------------------------------
CREATE TABLE comunicados (
  id       CHAR(36)     PRIMARY KEY,
  titulo   VARCHAR(255) NOT NULL,
  cuerpo   TEXT,
  imagen   VARCHAR(500) NOT NULL DEFAULT '',
  autor_id CHAR(36)     DEFAULT NULL,
  autor    VARCHAR(255) NOT NULL DEFAULT '',
  fijado   BOOLEAN      NOT NULL DEFAULT FALSE,
  visible  BOOLEAN      NOT NULL DEFAULT TRUE,
  creado   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (autor_id) REFERENCES usuarios(id) ON DELETE SET NULL,
  INDEX idx_comunicados_creado (creado DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 5. PLANES de membresía (van antes que tracks porque tracks los referencia)
--
--    SEGURIDAD EN PHP: cualquiera lee los activo=1; solo admin escribe.
-- ---------------------------------------------------------------------------
CREATE TABLE planes (
  id            CHAR(36)      PRIMARY KEY,
  orden         INT           NOT NULL DEFAULT 0,
  nombre        VARCHAR(255)  NOT NULL,
  dias          INT           NOT NULL DEFAULT 30,
  precio        DECIMAL(10,2) NOT NULL DEFAULT 0,
  descripcion   TEXT,
  beneficios    JSON,                             -- antes jsonb, array de strings
  limite_diario INT           NOT NULL DEFAULT 0, -- 0 = sin límite
  destacado     BOOLEAN       NOT NULL DEFAULT FALSE,
  activo        BOOLEAN       NOT NULL DEFAULT TRUE,
  creado        DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 6. CATÁLOGO
--
--    SEGURIDAD EN PHP:
--    - lee: cualquiera ve visible=1 (público); admin ve todo; editor ve
--      además sus propios tracks aunque estén ocultos.
--    - crea/edita/borra: editor solo si editor_id = su propio id; admin, todo.
-- ---------------------------------------------------------------------------
CREATE TABLE tracks (
  id          CHAR(36)      PRIMARY KEY,
  titulo      VARCHAR(255)  NOT NULL,
  artista     VARCHAR(255)  NOT NULL DEFAULT '',
  tipo        ENUM('edit','remix','mashup','intro','acapella','transicion') NOT NULL DEFAULT 'edit',
  genero      VARCHAR(100)  NOT NULL DEFAULT '',
  bpm         SMALLINT,
  tonalidad   VARCHAR(10)   NOT NULL DEFAULT '',
  duracion    VARCHAR(10)   NOT NULL DEFAULT '',
  anio        SMALLINT,
  portada     VARCHAR(500)  NOT NULL DEFAULT '',   -- imagen pública
  preview     VARCHAR(500)  NOT NULL DEFAULT '',   -- fragmento público (60-90s)
  editor_id   CHAR(36)      DEFAULT NULL,
  editor      VARCHAR(255)  NOT NULL DEFAULT '',   -- alias mostrado en la web
  editor_email VARCHAR(255) NOT NULL DEFAULT '',
  gratis      BOOLEAN       NOT NULL DEFAULT FALSE,
  precio      DECIMAL(10,2) NOT NULL DEFAULT 0,    -- > 0 = se compra suelto
  plan_minimo_id CHAR(36)   DEFAULT NULL,
  destacado   BOOLEAN       NOT NULL DEFAULT FALSE,
  visible     BOOLEAN       NOT NULL DEFAULT TRUE,
  descargas   INT           NOT NULL DEFAULT 0,
  creado      DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (editor_id) REFERENCES usuarios(id) ON DELETE SET NULL,
  FOREIGN KEY (plan_minimo_id) REFERENCES planes(id) ON DELETE SET NULL,
  INDEX idx_tracks_tipo (tipo),
  INDEX idx_tracks_genero (genero),
  INDEX idx_tracks_editor (editor_id),
  INDEX idx_tracks_creado (creado DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- La ruta del archivo COMPLETO vive aparte: así ningún visitante la puede leer
-- por simple curiosidad de la tabla tracks.
--
-- SEGURIDAD EN PHP: esta es LA tabla más sensible de todo el sistema. Nunca
-- se expone "ruta" directo en una respuesta pública. Solo un script PHP que
-- primero llama al equivalente de puede_descargar_track() (Fase 2) entrega el
-- archivo -- y ese script sirve el archivo él mismo (streaming), nunca un
-- link directo a la carpeta donde vive.
CREATE TABLE track_files (
  track_id CHAR(36)      PRIMARY KEY,
  ruta     VARCHAR(500)  NOT NULL,     -- ruta en el servidor, FUERA de la carpeta pública
  peso_mb  DECIMAL(10,2),
  formato  VARCHAR(10)   NOT NULL DEFAULT 'mp3',
  FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 7. COMPRA SUELTA de una o varias canciones (sin necesitar membresía).
--    El acceso comprado no vence: queda disponible para siempre.
--
--    SEGURIDAD EN PHP:
--    - crea: el propio usuario, siempre con estado='pendiente' (nunca deja
--      que el cliente mande estado='aprobada' por su cuenta).
--    - ve: el dueño ve las suyas; admin ve todas.
--    - cambia estado (aprobar/rechazar): SOLO admin.
-- ---------------------------------------------------------------------------
CREATE TABLE compras (
  id           CHAR(36)      PRIMARY KEY,
  user_id      CHAR(36)      NOT NULL,
  monto        DECIMAL(10,2) NOT NULL DEFAULT 0,
  metodo       VARCHAR(30)   NOT NULL DEFAULT 'yape',
  comprobante  VARCHAR(500)  NOT NULL DEFAULT '',   -- ruta privada, igual que track_files
  estado       ENUM('pendiente','aprobada','rechazada') NOT NULL DEFAULT 'pendiente',
  aprobado_por CHAR(36)      DEFAULT NULL,
  creado       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES usuarios(id) ON DELETE CASCADE,
  FOREIGN KEY (aprobado_por) REFERENCES usuarios(id) ON DELETE SET NULL,
  INDEX idx_compras_user (user_id),
  INDEX idx_compras_estado (estado)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE compra_tracks (
  compra_id CHAR(36)      NOT NULL,
  track_id  CHAR(36)      NOT NULL,
  precio    DECIMAL(10,2) NOT NULL DEFAULT 0,   -- precio al momento de comprar
  PRIMARY KEY (compra_id, track_id),
  FOREIGN KEY (compra_id) REFERENCES compras(id) ON DELETE CASCADE,
  FOREIGN KEY (track_id)  REFERENCES tracks(id)  ON DELETE CASCADE,
  INDEX idx_compra_tracks_tk (track_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 8. MEMBRESÍAS
--
--    SEGURIDAD EN PHP: igual patrón que compras -- el cliente solo crea
--    "pendiente"; solo admin aprueba/rechaza/edita estado.
-- ---------------------------------------------------------------------------
CREATE TABLE memberships (
  id            CHAR(36)      PRIMARY KEY,
  user_id       CHAR(36)      NOT NULL,
  plan_id       CHAR(36)      DEFAULT NULL,
  plan_nombre   VARCHAR(255)  NOT NULL DEFAULT '',
  monto         DECIMAL(10,2) NOT NULL DEFAULT 0,
  metodo        VARCHAR(30)   NOT NULL DEFAULT 'yape',
  comprobante   VARCHAR(500)  NOT NULL DEFAULT '',
  estado        ENUM('pendiente','activa','vencida','rechazada') NOT NULL DEFAULT 'pendiente',
  inicio        DATE,
  fin           DATE,
  notas         TEXT,
  aprobado_por  CHAR(36)      DEFAULT NULL,
  creado        DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES usuarios(id) ON DELETE CASCADE,
  FOREIGN KEY (plan_id) REFERENCES planes(id) ON DELETE SET NULL,
  FOREIGN KEY (aprobado_por) REFERENCES usuarios(id) ON DELETE SET NULL,
  INDEX idx_memb_user (user_id),
  INDEX idx_memb_estado (estado)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 9. DESCARGAS Y REPRODUCCIONES (historial)
--
--    SEGURIDAD EN PHP: solo se inserta desde el propio script de descarga/
--    reproducción, nunca desde un formulario libre. Lectura: el dueño ve las
--    suyas, admin/editor ven todo (para las estadísticas del panel).
-- ---------------------------------------------------------------------------
CREATE TABLE downloads (
  id       BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  creado   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  user_id  CHAR(36) DEFAULT NULL,
  track_id CHAR(36) DEFAULT NULL,
  FOREIGN KEY (user_id)  REFERENCES usuarios(id) ON DELETE SET NULL,
  FOREIGN KEY (track_id) REFERENCES tracks(id)   ON DELETE CASCADE,
  INDEX idx_dl_user (user_id, creado DESC),
  INDEX idx_dl_track (track_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE plays (
  id       BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  creado   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  track_id CHAR(36) DEFAULT NULL,
  user_id  CHAR(36) DEFAULT NULL,
  FOREIGN KEY (track_id) REFERENCES tracks(id)   ON DELETE CASCADE,
  FOREIGN KEY (user_id)  REFERENCES usuarios(id) ON DELETE SET NULL,
  INDEX idx_plays_track (track_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 10. SOLICITUDES DE BOOKING / CONTACTO
--
--     SEGURIDAD EN PHP: cualquiera (incluso sin sesión) puede crear una;
--     solo admin lee/gestiona la lista.
-- ---------------------------------------------------------------------------
CREATE TABLE bookings (
  id      CHAR(36)     PRIMARY KEY,
  creado  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  nombre  VARCHAR(255) NOT NULL DEFAULT '',
  email   VARCHAR(255) NOT NULL DEFAULT '',
  tipo    VARCHAR(100) NOT NULL DEFAULT '',
  fecha   DATE,
  lugar   VARCHAR(255) NOT NULL DEFAULT '',
  mensaje TEXT,
  estado  ENUM('nuevo','cotizado','cerrado','perdido') NOT NULL DEFAULT 'nuevo',
  notas   TEXT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 11. TRIGGER: contador de descargas por track
--     (este sí se queda en la base de datos, no depende de quién esté
--     logueado -- es puramente aritmético, igual que en Supabase)
-- ---------------------------------------------------------------------------
DELIMITER $$
CREATE TRIGGER trg_sumar_descarga AFTER INSERT ON downloads
FOR EACH ROW
BEGIN
  UPDATE tracks SET descargas = descargas + 1 WHERE id = NEW.track_id;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------------
-- 12. DATOS INICIALES (planes y crew de ejemplo, igual que en Supabase)
-- ---------------------------------------------------------------------------
INSERT INTO planes (id, orden, nombre, dias, precio, descripcion, beneficios, limite_diario, destacado) VALUES
  (UUID(), 1, 'Semanal',   7,  15.00, 'Para probar el pool una semana completa.',
    JSON_ARRAY('Acceso a todo el catálogo','Descargas ilimitadas','Novedades de la semana'), 0, FALSE),
  (UUID(), 2, 'Mensual',  30,  40.00, 'El plan que usa la mayoría del crew.',
    JSON_ARRAY('Acceso a todo el catálogo','Descargas ilimitadas','Lanzamientos semanales','Soporte por WhatsApp'), 0, TRUE),
  (UUID(), 3, 'Trimestral', 90, 100.00, 'Tres meses al precio de dos y medio.',
    JSON_ARRAY('Todo lo del plan Mensual','Ahorro de S/ 20','Pedidos de edits a medida'), 0, FALSE),
  (UUID(), 4, 'Anual', 365, 320.00, 'Para el DJ que trabaja todas las semanas.',
    JSON_ARRAY('Todo lo del plan Trimestral','Dos meses gratis','Acceso anticipado a estrenos'), 0, FALSE);

INSERT INTO crew (id, orden, alias, nombre, cargo, bio) VALUES
  (UUID(), 1, 'DJ Ronald', 'Ronald Moscol', 'Fundador · Director',
    'Creador de VIP PAITA MIX en 2016. Cumbia, tecnocumbia y todo lo que mueve el norte.'),
  (UUID(), 2, 'DJ Invitado 2', '', 'DJ / Editor', ''),
  (UUID(), 3, 'DJ Invitado 3', '', 'DJ / Editor', ''),
  (UUID(), 4, 'DJ Invitado 4', '', 'DJ / Editor', ''),
  (UUID(), 5, 'DJ Invitado 5', '', 'DJ / Editor', '');

SET FOREIGN_KEY_CHECKS = 1;

-- ============================================================================
--  LO QUE NO ESTÁ AQUÍ TODAVÍA (a propósito -- son las siguientes fases):
--
--  - Fase 2: las funciones que en Supabase usaban auth.uid() -- membresia_activa(),
--    puede_descargar_track(), solicitar_descarga(), aprobar_membresia(),
--    aprobar_compra(), mi_membresia(), cambiar_rol() -- se van a escribir
--    como funciones de PHP (no como procedimientos de MySQL), porque PHP ya
--    sabe quién está logueado por la sesión, y es mucho más fácil de mantener
--    ahí que en SQL puro.
--  - Fase 3: usuarios, login, contraseñas, recuperar contraseña.
--  - Fase 4: subida y entrega de archivos (hoy "Storage" de Supabase).
-- ============================================================================
