#!/bin/bash
# Verifica una migración: compara Supabase (origen) contra MySQL (destino)
# registro por registro, y prueba por HTTP que lo migrado funcione de verdad.
# Pensado para el ensayo local: Supabase en Docker (supabase start) y los
# contenedores vpm-mysql-test / vpm-php-test con datos.sql ya importado.
# OJO: correrlo justo después de importar. La verificación hace descargas de
# verdad (que suman al contador), así que una segunda corrida sobre la misma
# base ya no coincide con Supabase en esos puntos.
BASE="http://127.0.0.1:8099"; PUB="$BASE/api/publica.php"; PANEL="$BASE/api/panel.php"; H="X-VPM: 1"
FALLOS=0
export PYTHONIOENCODING=utf-8
verificar() {
  if [ "$2" = "$3" ]; then echo "OK    - $1"; else echo "FALLO - $1 (esperado=$2, obtuvo=$3)"; FALLOS=$((FALLOS+1)); fi
}
pg() { docker exec supabase_db_vip-paita-mix psql -U postgres -d postgres -tAc "$1" 2>/dev/null; }
my() { docker exec vpm-mysql-test mysql -uroot -ptest1234 vip_paita_mix --default-character-set=utf8mb4 -N -e "SET SESSION group_concat_max_len=100000000; $1" 2>/dev/null; }
json() { python -c "import sys,json; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1"; }
login() { curl -s -c "/tmp/ckm_$1" -H "$H" -d "email=$2&password=$3" "$PUB?accion=login"; }
bajar() { curl -s -b "/tmp/ckm_$1" "$BASE/$2"; }

echo "=== Cantidad de registros por tabla (Supabase -> MySQL) ==="
for par in "auth.users:usuarios" "public.settings:settings" "public.crew:crew" "public.comunicados:comunicados" \
           "public.plans:planes" "public.tracks:tracks" "public.track_files:track_files" "public.compras:compras" \
           "public.compra_tracks:compra_tracks" "public.memberships:memberships" "public.downloads:downloads" \
           "public.plays:plays" "public.bookings:bookings"; do
  o=${par%%:*}; d=${par##*:}
  verificar "$d" "$(pg "select count(*) from $o")" "$(my "SELECT COUNT(*) FROM $d")"
done

echo ""
echo "=== Contenido idéntico (huella de cada tabla, campo por campo) ==="
# mismo orden en ambos lados: por id como texto binario
verificar "usuarios: id, correo, rol y nombre" \
  "$(pg "select md5(string_agg(u.id::text||'|'||lower(u.email)||'|'||coalesce(p.rol,'member')||'|'||coalesce(p.nombre,''), ',' order by u.id::text collate \"C\")) from auth.users u left join public.profiles p on p.id=u.id")" \
  "$(my "SELECT MD5(GROUP_CONCAT(CONCAT(id,'|',email,'|',rol,'|',nombre) ORDER BY BINARY id SEPARATOR ',')) FROM usuarios")"
verificar "usuarios: la huella de la contraseña viaja intacta" \
  "$(pg "select md5(string_agg(encrypted_password, ',' order by id::text collate \"C\")) from auth.users where encrypted_password like '\$2%'")" \
  "$(my "SELECT MD5(GROUP_CONCAT(password_hash ORDER BY BINARY id SEPARATOR ',')) FROM usuarios WHERE password_hash LIKE '\$2%'")"
verificar "tracks: título, artista, descargas, precio, plan mínimo, gratis" \
  "$(pg "select md5(string_agg(id::text||'|'||titulo||'|'||coalesce(artista,'')||'|'||coalesce(descargas,0)||'|'||coalesce(precio,0)::numeric(10,2)||'|'||coalesce(plan_minimo_id::text,'')||'|'||coalesce(gratis,false)::int, ',' order by id::text collate \"C\")) from public.tracks")" \
  "$(my "SELECT MD5(GROUP_CONCAT(CONCAT(id,'|',titulo,'|',artista,'|',descargas,'|',precio,'|',IFNULL(plan_minimo_id,''),'|',gratis) ORDER BY BINARY id SEPARATOR ',')) FROM tracks")"
verificar "membresías: estado, fechas y hora de creación (en hora de Lima)" \
  "$(pg "select md5(string_agg(id::text||'|'||estado||'|'||coalesce(inicio::text,'')||'|'||coalesce(fin::text,'')||'|'||to_char(creado at time zone 'America/Lima','YYYY-MM-DD HH24:MI:SS'), ',' order by id::text collate \"C\")) from public.memberships")" \
  "$(my "SELECT MD5(GROUP_CONCAT(CONCAT(id,'|',estado,'|',IFNULL(inicio,''),'|',IFNULL(fin,''),'|',DATE_FORMAT(creado,'%Y-%m-%d %H:%i:%s')) ORDER BY BINARY id SEPARATOR ',')) FROM memberships")"
verificar "mensajes: textos con comillas, barras, saltos de línea y emojis" \
  "$(pg "select md5(string_agg(id::text||'|'||coalesce(nombre,'')||'|'||coalesce(mensaje,''), ',' order by id::text collate \"C\")) from public.bookings")" \
  "$(my "SELECT MD5(GROUP_CONCAT(CONCAT(id,'|',nombre,'|',IFNULL(mensaje,'')) ORDER BY BINARY id SEPARATOR ',')) FROM bookings")"
verificar "comunicados: título y cuerpo" \
  "$(pg "select md5(string_agg(id::text||'|'||titulo||'|'||coalesce(cuerpo,''), ',' order by id::text collate \"C\")) from public.comunicados")" \
  "$(my "SELECT MD5(GROUP_CONCAT(CONCAT(id,'|',titulo,'|',IFNULL(cuerpo,'')) ORDER BY BINARY id SEPARATOR ',')) FROM comunicados")"
verificar "descargas: quién, qué y cuándo" \
  "$(pg "select md5(string_agg(id||'|'||coalesce(user_id::text,'')||'|'||coalesce(track_id::text,'')||'|'||to_char(creado at time zone 'America/Lima','YYYY-MM-DD HH24:MI:SS'), ',' order by id)) from public.downloads")" \
  "$(my "SELECT MD5(GROUP_CONCAT(CONCAT(id,'|',IFNULL(user_id,''),'|',IFNULL(track_id,''),'|',DATE_FORMAT(creado,'%Y-%m-%d %H:%i:%s')) ORDER BY id SEPARATOR ',')) FROM downloads")"
verificar "el contador del track 1 NO se duplicó al importar las descargas" "3" \
  "$(my "SELECT descargas FROM tracks WHERE id='aaaaaaaa-0000-4000-8000-000000000001'")"
verificar "un artista NULL de Supabase queda vacío (no rompe la importación)" "" \
  "$(my "SELECT artista FROM tracks WHERE id='aaaaaaaa-0000-4000-8000-000000000003'")"

echo ""
echo "=== Los miembros entran con su contraseña de siempre ==="
verificar "miembro (bcrypt \$2a\$10\$) entra con su clave original" "member" "$(login soc socio.real@test.com MiClave2026 | json "['usuario']['rol']")"
verificar "admin (bcrypt \$2a\$06\$) entra con su clave original" "admin" "$(login adm admin_audio_test@test.com password123 | json "['usuario']['rol']")"
verificar "editor entra al panel con su clave original" "editor" "$(login dj dj.real@test.com ClaveDJ99 >/dev/null; curl -s -b /tmp/ckm_dj "$PANEL?accion=yo" | json "['perfil']['rol']")"
verificar "con una clave equivocada no entra" "False" "$(curl -s -H "$H" -d 'email=socio.real@test.com&password=otra' "$PUB?accion=login" | json "['ok']")"
verificar "los nombres con tildes y ñ llegan bien" "José Ñáñez" "$(curl -s -b /tmp/ckm_soc "$PUB?accion=sesion" | json "['usuario']['nombre']")"

echo ""
echo "=== Su membresía, sus compras y sus descargas siguen igual ==="
R=$(curl -s -b /tmp/ckm_soc "$PUB?accion=mi_cuenta")
verificar "la membresía sigue activa" "activa" "$(echo "$R" | json "['membresia']['estado']")"
verificar "con su mismo plan" "Mensual" "$(echo "$R" | json "['membresia']['plan']")"
verificar "la canción comprada suelta sigue siendo suya" "True" "$(echo "$R" | json "['comprados'].__contains__('aaaaaaaa-0000-4000-8000-000000000002')")"
URL=$(curl -s -b /tmp/ckm_soc -H "$H" -d "track_id=aaaaaaaa-0000-4000-8000-000000000001" "$PUB?accion=solicitar_descarga" | json "['url']")
verificar "descarga el archivo completo migrado, con su contenido exacto" "ARCHIVO COMPLETO DEL TRACK 1" "$(bajar soc "$URL")"
URL=$(curl -s -b /tmp/ckm_soc -H "$H" -d "track_id=aaaaaaaa-0000-4000-8000-000000000002" "$PUB?accion=solicitar_descarga" | json "['url']")
verificar "descarga el track premium que compró suelto" "ARCHIVO COMPLETO PREMIUM" "$(bajar soc "$URL")"
verificar "y la descarga nueva suma 1 al contador (3 -> 4)" "4" "$(my "SELECT descargas FROM tracks WHERE id='aaaaaaaa-0000-4000-8000-000000000001'")"

echo ""
echo "=== Archivos públicos y marca ==="
R=$(curl -s "$PUB?accion=inicio")
PORT=$(echo "$R" | python -c "import sys,json; print([t for t in json.load(sys.stdin)['tracks'] if t['id']=='aaaaaaaa-0000-4000-8000-000000000001'][0]['portada'])")
verificar "la portada apunta al hosting nuevo, ya no a Supabase" "/subidas/portadas/ensayo-t1-portada.jpg" "$PORT"
verificar "y se ve por la web, con su contenido exacto" "portada del track 1" "$(curl -s "$BASE$PORT")"
IMG=$(echo "$R" | python -c "import sys,json; print([c for c in json.load(sys.stdin)['comunicados'] if c['titulo'].startswith('Pack de A')][0]['imagen'])")
verificar "una imagen con espacios en el nombre también se ve" "foto con espacio en el nombre" "$(curl -s "$BASE$IMG")"
verificar "el logo apunta al hosting nuevo" "/subidas/portadas/ensayo-logo.png" "$(echo "$R" | json "['settings']['logo_url']")"
verificar "el audio destacado del inicio suena desde el hosting nuevo" "audio destacado del hero" "$(curl -s "$BASE$(echo "$R" | json "['settings']['audio_destacado_archivo']")")"
verificar "el link de YouTube (externo) se dejó igual" "https://www.youtube.com/watch?v=dQw4w9WgXcQ" "$(echo "$R" | json "['settings']['video_url']")"
verificar "las frases del letrero, con tildes y ñ" "['Edits', 'Remixes', 'Reggaetón', 'Peñas']" "$(echo "$R" | json "['settings']['frases']")"
verificar "el emoji del comunicado llega bien" "True" "$(echo "$R" | python -c "import sys,json; print(any('🎆' in c['titulo'] for c in json.load(sys.stdin)['comunicados']))")"
verificar "las fechas llegan al navegador con su zona horaria" "-05:00" "$(echo "$R" | json "['tracks'][0]['creado'][-6:]")"
verificar "ninguna URL de Supabase quedó en la base de datos" "0" \
  "$(my "SELECT (SELECT COUNT(*) FROM tracks WHERE portada LIKE '%supabase%' OR preview LIKE '%supabase%' OR portada LIKE '%/storage/v1/%' OR preview LIKE '%/storage/v1/%')
              + (SELECT COUNT(*) FROM settings WHERE CONCAT(logo_url,hero_img,yape_qr,audio_destacado_archivo,video_archivo,hero_video_fondo) LIKE '%/storage/v1/%')
              + (SELECT COUNT(*) FROM crew WHERE foto LIKE '%/storage/v1/%') + (SELECT COUNT(*) FROM comunicados WHERE imagen LIKE '%/storage/v1/%')")"

echo ""
echo "=== Comprobantes de pago migrados (privados) ==="
RUTA=$(my "SELECT comprobante FROM memberships WHERE user_id='11111111-1111-4111-8111-111111111111' AND estado='activa'")
verificar "el comprobante quedó en la carpeta privada" "comprobantes/11111111-1111-4111-8111-111111111111/ensayo-pago.jpg" "$RUTA"
verificar "el admin lo ve, con su contenido exacto" "captura del pago de membresia" "$(bajar adm "ver_comprobante.php?ruta=$RUTA")"
verificar "el dueño también lo ve" "captura del pago de membresia" "$(bajar soc "ver_comprobante.php?ruta=$RUTA")"
verificar "otra persona (el editor) NO" "403" "$(curl -s -o /dev/null -w '%{http_code}' -b /tmp/ckm_dj "$BASE/ver_comprobante.php?ruta=$RUTA")"
verificar "nadie lo puede abrir por URL directa" "404" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/$RUTA")"

echo ""
echo "=== El panel muestra lo migrado ==="
# se compara la huella md5 y no el texto impreso: en Windows, Python cambia
# cada salto de línea por \r\n al imprimir y la comparación mentiría
MSG=$(curl -s -b /tmp/ckm_adm "$PANEL?accion=mensajes" | python -c "import sys,json,hashlib; m=[m for m in json.load(sys.stdin)['mensajes'] if m['email']=='obrien@test.com'][0]['mensaje']; print(hashlib.md5(m.encode('utf-8')).hexdigest())")
ORIG=$(pg "select md5(mensaje) from public.bookings where email='obrien@test.com'")
verificar "el mensaje con comillas, barra y el intento de inyección llega idéntico al panel" "$ORIG" "$MSG"
verificar "la tabla usuarios sigue existiendo (el 'DROP TABLE' del mensaje es solo texto)" "$(pg "select count(*) from auth.users")" "$(my "SELECT COUNT(*) FROM usuarios")"

rm -f /tmp/ckm_*
echo ""
if [ "$FALLOS" -eq 0 ]; then echo "TODO OK (0 fallos)"; else echo "HAY $FALLOS FALLO(S)"; fi
exit $FALLOS
