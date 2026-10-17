#!/bin/bash
# Prueba la API del panel (web/api/panel.php) contra un servidor PHP real,
# con cuentas de admin, dos editores y un miembro. Base de datos limpia
# (solo schema.sql) y servidor en http://127.0.0.1:8099.
PUB="http://127.0.0.1:8099/api/publica.php"
PANEL="http://127.0.0.1:8099/api/panel.php"
H="X-VPM: 1"
FALLOS=0
export PYTHONIOENCODING=utf-8
verificar() {
  if [ "$2" = "$3" ]; then echo "OK    - $1"; else echo "FALLO - $1 (esperado=$2, obtuvo=$3)"; FALLOS=$((FALLOS+1)); fi
}
json() { python -c "import sys,json; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1"; }
jsonx() { python -c "import sys,json; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
sql() { docker exec vpm-mysql-test mysql -uroot -ptest1234 vip_paita_mix -N -e "$1" 2>/dev/null; }
# El JSON se pasa por archivo y no como argumento: en Windows, Git Bash le
# entrega los argumentos a curl en otra codificación y las tildes llegarían
# rotas (el navegador real siempre manda UTF-8).
# post <cookie> <accion> <json>   -> cuerpo de la respuesta
post() { printf '%s' "$3" > /tmp/cuerpo.json
  curl -s -b "/tmp/ck_$1" -H "$H" -H "Content-Type: application/json" --data-binary @/tmp/cuerpo.json "$PANEL?accion=$2"; }
# cod <cookie> <accion> <json>    -> solo el código HTTP
cod() { printf '%s' "$3" > /tmp/cuerpo.json
  curl -s -o /dev/null -w "%{http_code}" -b "/tmp/ck_$1" -H "$H" -H "Content-Type: application/json" --data-binary @/tmp/cuerpo.json "$PANEL?accion=$2"; }
# ¿existe este archivo dentro del servidor? (MSYS_NO_PATHCONV evita que Git
# Bash convierta /app/... en una ruta de Windows y la revisión mienta)
existe() { MSYS_NO_PATHCONV=1 docker exec vpm-php-test test -f "$1" && echo si || echo no; }
get() { curl -s -b "/tmp/ck_$1" "$PANEL?accion=$2"; }
getcod() { curl -s -o /dev/null -w "%{http_code}" -b "/tmp/ck_$1" "$PANEL?accion=$2"; }
login() { curl -s -c "/tmp/ck_$1" -H "$H" -d "email=$2&password=$3" "$PUB?accion=login" >/dev/null; }
subir() { curl -s -b "/tmp/ck_$1" -F "bucket=$2" -F "archivo=@$3" "http://127.0.0.1:8099/subir.php" | sed 's/^OK://'; }

rm -f /tmp/ck_*
echo "audio" > /tmp/cancion.mp3; echo "img" > /tmp/portada.jpg; echo "img" > /tmp/logo.png; echo "pago" > /tmp/pago.jpg

# ---- cuentas ----
curl -s -c /tmp/ck_adm -H "$H" -d "email=admin@test.com&password=claveadmin&nombre=Ronald" "$PUB?accion=registrar" >/dev/null
post adm crear_usuario '{"email":"edA@test.com","password":"claveA1","nombre":"Editor A","alias":"DJ Alfa","rol":"editor"}' >/dev/null
post adm crear_usuario '{"email":"edB@test.com","password":"claveB1","nombre":"Editor B","alias":"DJ Beta","rol":"editor"}' >/dev/null
post adm crear_usuario '{"email":"socio@test.com","password":"claveS1","nombre":"Socio","rol":"member"}' >/dev/null
login edA edA@test.com claveA1; login edB edB@test.com claveB1; login soc socio@test.com claveS1
ADM=$(sql "SELECT id FROM usuarios WHERE email='admin@test.com'")
EDA=$(sql "SELECT id FROM usuarios WHERE email='eda@test.com'")
EDB=$(sql "SELECT id FROM usuarios WHERE email='edb@test.com'")
SOC=$(sql "SELECT id FROM usuarios WHERE email='socio@test.com'")

echo "=== Quién entra al panel ==="
verificar "sin sesión -> 403" "403" "$(curl -s -o /dev/null -w '%{http_code}' "$PANEL?accion=yo")"
verificar "un miembro normal -> 403" "403" "$(getcod soc yo)"
verificar "un editor entra, con su rol" "editor" "$(get edA yo | json "['perfil']['rol']")"
verificar "un POST sin la cabecera X-VPM -> 403 (anti-CSRF)" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' -b /tmp/ck_adm -H 'Content-Type: application/json' -d '{}' "$PANEL?accion=guardar_settings")"

echo ""
echo "=== Lo que un editor NO puede hacer ==="
for a in contadores resumen membresias compras miembros usuarios planes crew settings mensajes; do
  verificar "editor no puede leer '$a'" "403" "$(getcod edA $a)"
done
verificar "editor no puede cambiar roles" "403" "$(cod edA cambiar_rol "{\"id\":\"$SOC\",\"rol\":\"admin\"}")"
verificar "editor no puede crear cuentas" "403" "$(cod edA crear_usuario '{"email":"x@x.com","password":"123456","rol":"admin"}')"
verificar "editor no puede tocar la marca" "403" "$(cod edA guardar_settings '{"marca":"Hackeado"}')"
verificar "editor no puede aprobar pagos" "403" "$(cod edA aprobar_membresia '{"id":"x"}')"
verificar "editor no puede resetear claves" "403" "$(cod edA resetear_password "{\"id\":\"$ADM\",\"password\":\"123456\"}")"

echo ""
echo "=== Tracks: cada editor solo lo suyo ==="
RUTA_A=$(subir edA descargas /tmp/cancion.mp3)
verificar "el editor sube el archivo completo a la carpeta privada" "descargas/" "${RUTA_A:0:10}"
R=$(post edA guardar_track "{\"titulo\":\"Track de Alfa\",\"tipo\":\"remix\",\"precio\":\"3.5\",\"archivo\":\"$RUTA_A\",\"editor_id\":\"$ADM\",\"editor\":\"Suplantado\"}")
TA=$(echo "$R" | json "['id']")
verificar "el editor crea su track" "True" "$(echo "$R" | json "['ok']")"
verificar "aunque mande editor_id ajeno, el track queda a su nombre" "$EDA" "$(sql "SELECT editor_id FROM tracks WHERE id='$TA'")"
verificar "el alias mostrado sale de su cuenta, no del navegador" "DJ Alfa" "$(sql "SELECT editor FROM tracks WHERE id='$TA'")"
verificar "el archivo completo queda enlazado al track" "$RUTA_A" "$(sql "SELECT ruta FROM track_files WHERE track_id='$TA'")"

verificar "editor B no ve el track de A" "0" "$(get edB tracks | json "['tracks'].__len__()")"
verificar "editor B no puede editar el track de A" "403" "$(cod edB guardar_track "{\"id\":\"$TA\",\"titulo\":\"Robado\"}")"
verificar "editor B no puede borrar el track de A" "403" "$(cod edB borrar_track "{\"id\":\"$TA\"}")"
verificar "el título sigue intacto" "Track de Alfa" "$(sql "SELECT titulo FROM tracks WHERE id='$TA'")"
verificar "el admin sí ve el track de A, con su archivo" "$RUTA_A" "$(get adm tracks | json "['archivos']['$TA']")"

verificar "no acepta un 'archivo completo' fuera de descargas/" "400" "$(cod edA guardar_track '{"titulo":"X","archivo":"../../auth.php"}')"
verificar "no acepta un archivo que no fue subido de verdad" "400" "$(cod edA guardar_track '{"titulo":"X","archivo":"descargas/inventado.mp3"}')"
verificar "no acepta un tipo inventado" "400" "$(cod edA guardar_track '{"titulo":"X","tipo":"virus"}')"
verificar "no acepta un plan mínimo que no existe" "400" "$(cod edA guardar_track '{"titulo":"X","plan_minimo_id":"no-existe"}')"

post adm guardar_track "{\"id\":\"$TA\",\"titulo\":\"Track de Alfa\",\"editor_id\":\"$EDB\"}" >/dev/null
verificar "el admin sí puede reasignar un track a otro DJ" "DJ Beta" "$(sql "SELECT editor FROM tracks WHERE id='$TA'")"
post adm guardar_track "{\"id\":\"$TA\",\"titulo\":\"Track de Alfa\",\"editor_id\":\"$SOC\"}" >/dev/null
verificar "pero no a alguien que no es del equipo" "DJ Beta" "$(sql "SELECT editor FROM tracks WHERE id='$TA'")"

echo ""
echo "=== Borrar un track no borra archivos ajenos ==="
LOGO=$(subir adm portadas /tmp/logo.png)
post adm guardar_settings "{\"logo_url\":\"/subidas/$LOGO\"}" >/dev/null
verificar "control: el logo existe antes de la prueba" "si" "$(existe /app/web/subidas/$LOGO)"
R=$(post edA guardar_track "{\"titulo\":\"Trampa\",\"portada\":\"/subidas/$LOGO\"}")
post edA borrar_track "{\"id\":\"$(echo "$R" | json "['id']")\"}" >/dev/null
verificar "el track 'trampa' sí se borró" "0" "$(sql "SELECT COUNT(*) FROM tracks WHERE titulo='Trampa'")"
verificar "pero el logo sigue existiendo aunque el track lo usara de portada" "si" "$(existe /app/web/subidas/$LOGO)"

PORT=$(subir edA portadas /tmp/portada.jpg)
RUTA_A2=$(subir edA descargas /tmp/cancion.mp3)
R=$(post edA guardar_track "{\"titulo\":\"Para borrar\",\"portada\":\"/subidas/$PORT\",\"archivo\":\"$RUTA_A2\"}")
verificar "control: la portada y el archivo existen antes de borrar" "si si" \
  "$(existe /app/web/subidas/$PORT) $(existe /app/privado/$RUTA_A2)"
post edA borrar_track "{\"id\":\"$(echo "$R" | json "['id']")\"}" >/dev/null
verificar "al borrar su propio track, se borra su portada" "no" "$(existe /app/web/subidas/$PORT)"
verificar "y también su archivo completo privado" "no" "$(existe /app/privado/$RUTA_A2)"
verificar "pero NO el archivo de otro track que sigue vivo" "si" "$(existe /app/privado/$RUTA_A)"

echo ""
echo "=== Pagos y compras ==="
PLAN=$(sql "SELECT id FROM planes WHERE nombre='Mensual'")
curl -s -b /tmp/ck_soc -H "$H" -F "plan_id=$PLAN" -F "comprobante=@/tmp/pago.jpg" "$PUB?accion=solicitar_membresia" >/dev/null
curl -s -b /tmp/ck_soc -H "$H" -F "plan_id=$PLAN" -F "comprobante=@/tmp/pago.jpg" "$PUB?accion=solicitar_membresia" >/dev/null
read M1 M2 <<< $(sql "SELECT id FROM memberships ORDER BY id" | tr '\n' ' ')
verificar "el admin ve los pagos con el correo del miembro" "socio@test.com" "$(get adm membresias | json "['membresias'][0]['email']")"
post adm aprobar_membresia "{\"id\":\"$M1\"}" >/dev/null
verificar "aprobar activa la membresía" "activa" "$(sql "SELECT estado FROM memberships WHERE id='$M1'")"
post adm rechazar_membresia "{\"id\":\"$M2\"}" >/dev/null
verificar "rechazar la marca como rechazada" "rechazada" "$(sql "SELECT estado FROM memberships WHERE id='$M2'")"
verificar "cambiar vencimiento con fecha inválida -> 400" "400" "$(cod adm cambiar_fin_membresia "{\"id\":\"$M1\",\"fin\":\"2026-02-31\"}")"
post adm cambiar_fin_membresia "{\"id\":\"$M1\",\"fin\":\"2027-01-15\"}" >/dev/null
verificar "cambiar vencimiento con fecha válida" "2027-01-15" "$(sql "SELECT fin FROM memberships WHERE id='$M1'")"
verificar "el miembro aparece activo en la lista de miembros" "activa" "$(get adm miembros | json "['miembros'][0]['estado']")"

post adm guardar_track "{\"id\":\"$TA\",\"titulo\":\"Track de Alfa\",\"editor_id\":\"$EDB\",\"precio\":5}" >/dev/null
curl -s -b /tmp/ck_soc -H "$H" -F "track_ids=$TA" -F "comprobante=@/tmp/pago.jpg" "$PUB?accion=solicitar_compra" >/dev/null
CID=$(sql "SELECT id FROM compras LIMIT 1")
verificar "el admin ve la compra con el título de la canción" "Track de Alfa" "$(get adm compras | json "['compras'][0]['tracks'][0]['titulo']")"
post adm aprobar_compra "{\"id\":\"$CID\"}" >/dev/null
verificar "aprobar la compra la deja aprobada" "aprobada" "$(sql "SELECT estado FROM compras WHERE id='$CID'")"
verificar "contadores: 0 pagos pendientes" "0" "$(get adm contadores | json "['pagos']")"

echo ""
echo "=== Cuentas y roles ==="
verificar "crear cuenta con clave corta -> 400" "400" "$(cod adm crear_usuario '{"email":"corta@test.com","password":"12","rol":"member"}')"
verificar "y la cuenta NO quedó creada a medias" "" "$(sql "SELECT id FROM usuarios WHERE email='corta@test.com'")"
verificar "el admin no puede quitarse su propio rol" "400" "$(cod adm cambiar_rol "{\"id\":\"$ADM\",\"rol\":\"member\"}")"
verificar "el admin no puede borrar su propia cuenta" "400" "$(cod adm borrar_usuario "{\"id\":\"$ADM\"}")"
verificar "editar con un correo que ya usa otra cuenta -> 400" "400" "$(cod adm editar_usuario "{\"id\":\"$SOC\",\"email\":\"eda@test.com\"}")"
post adm editar_usuario "{\"id\":\"$SOC\",\"email\":\"Socio2@Test.com\",\"nombre\":\"Socio Editado\",\"telefono\":\"999-111-222\"}" >/dev/null
verificar "editar guarda correo en minúsculas y teléfono solo dígitos" "socio2@test.com 999111222" "$(sql "SELECT CONCAT(email,' ',telefono) FROM usuarios WHERE id='$SOC'")"
post adm resetear_password "{\"id\":\"$SOC\",\"password\":\"nuevaclave9\"}" >/dev/null
verificar "tras el reset, el miembro entra con la clave nueva" "True" \
  "$(curl -s -H "$H" -d 'email=socio2@test.com&password=nuevaclave9' "$PUB?accion=login" | json "['ok']")"
post adm cambiar_rol "{\"id\":\"$EDB\",\"rol\":\"member\"}" >/dev/null
verificar "al bajar a editor B a miembro, pierde el panel" "403" "$(getcod edB yo)"

echo ""
echo "=== Planes y crew ==="
R=$(post adm guardar_plan '{"nombre":"VIP","dias":60,"precio":70,"beneficios":["Todo","Prioridad",""],"activo":true}')
VIP=$(echo "$R" | json "['id']")
verificar "plan nuevo queda al final del orden" "5" "$(sql "SELECT orden FROM planes WHERE id='$VIP'")"
verificar "los beneficios vacíos se descartan" "['Todo', 'Prioridad']" "$(get adm planes | jsonx "[x for x in d['planes'] if x['id']=='$VIP'][0]['beneficios']")"
ANUAL=$(sql "SELECT id FROM planes WHERE nombre='Anual'")
post adm intercambiar_orden "{\"tabla\":\"planes\",\"a\":\"$VIP\",\"b\":\"$ANUAL\"}" >/dev/null
verificar "intercambiar orden" "4 5" "$(sql "SELECT CONCAT((SELECT orden FROM planes WHERE id='$VIP'),' ',(SELECT orden FROM planes WHERE id='$ANUAL'))")"
verificar "borrar_fila no acepta tablas fuera de la lista" "400" "$(cod adm borrar_fila "{\"tabla\":\"usuarios\",\"id\":\"$SOC\"}")"
verificar "y el usuario sigue existiendo" "$SOC" "$(sql "SELECT id FROM usuarios WHERE id='$SOC'")"
post adm guardar_crew '{"alias":"DJ Beta","email":"beta@crew.com","cargo":""}' >/dev/null
verificar "el correo del crew se copia a sus tracks" "beta@crew.com" "$(sql "SELECT editor_email FROM tracks WHERE id='$TA'")"
verificar "cargo vacío toma el valor por defecto" "DJ / Editor" "$(sql "SELECT cargo FROM crew WHERE alias='DJ Beta'")"

echo ""
echo "=== Comunicados ==="
R=$(post edA guardar_comunicado '{"titulo":"Pack de Halloween","cuerpo":"Ya salió","visible":true}')
CA=$(echo "$R" | json "['id']")
verificar "el comunicado queda firmado con el alias de su autor" "DJ Alfa" "$(sql "SELECT autor FROM comunicados WHERE id='$CA'")"
verificar "las tildes se guardan bien" "Ya salió" "$(get edA comunicados | json "['comunicados'][0]['cuerpo']")"
post adm cambiar_rol "{\"id\":\"$EDB\",\"rol\":\"editor\"}" >/dev/null
verificar "otro editor no puede editarlo" "403" "$(cod edB guardar_comunicado "{\"id\":\"$CA\",\"titulo\":\"Cambiado\"}")"
verificar "otro editor no puede borrarlo" "403" "$(cod edB borrar_comunicado "{\"id\":\"$CA\"}")"
post adm guardar_comunicado "{\"id\":\"$CA\",\"titulo\":\"Pack de Halloween 2026\",\"visible\":true}" >/dev/null
verificar "el admin sí puede editarlo" "Pack de Halloween 2026" "$(sql "SELECT titulo FROM comunicados WHERE id='$CA'")"
verificar "y se ve en la web pública" "Pack de Halloween 2026" "$(curl -s "$PUB?accion=inicio" | json "['comunicados'][0]['titulo']")"

echo ""
echo "=== Marca y contacto ==="
verificar "un color mal escrito -> 400" "400" "$(cod adm guardar_settings '{"color_acento":"rojo"}')"
verificar "un tema inventado -> 400" "400" "$(cod adm guardar_settings '{"tema":"pascua"}')"
post adm guardar_settings '{"marca":"VIP PAITA MIX","tema":"halloween","video_activo":true,"frases":["Cumbia","Salsa"],"id":99,"rol":"admin"}' >/dev/null
verificar "guarda tema, video y frases" "halloween 1" "$(sql "SELECT CONCAT(tema,' ',video_activo) FROM settings")"
verificar "las frases vuelven como lista en la web" "['Cumbia', 'Salsa']" "$(curl -s "$PUB?accion=inicio" | json "['settings']['frases']")"
verificar "columnas desconocidas (id, rol) se ignoran" "1" "$(sql "SELECT COUNT(*) FROM settings WHERE id=1")"

echo ""
echo "=== Mensajes ==="
curl -s -H "$H" -d "nombre=Boda&email=b@b.com&mensaje=Hola" "$PUB?accion=booking" >/dev/null
BK=$(get adm mensajes | json "['mensajes'][0]['id']")
verificar "estado de mensaje inventado -> 400" "400" "$(cod adm estado_mensaje "{\"id\":\"$BK\",\"estado\":\"spam\"}")"
post adm estado_mensaje "{\"id\":\"$BK\",\"estado\":\"cotizado\"}" >/dev/null
verificar "cambiar estado del mensaje" "cotizado" "$(sql "SELECT estado FROM bookings WHERE id='$BK'")"
post adm borrar_mensaje "{\"id\":\"$BK\"}" >/dev/null
verificar "borrar mensaje" "0" "$(sql "SELECT COUNT(*) FROM bookings")"

echo ""
echo "=== Resumen ==="
R=$(get adm resumen)
verificar "resumen: 1 miembro activo" "1" "$(echo "$R" | json "['activos']")"
verificar "resumen: ingresos del mes (40 de la membresía aprobada)" "40.0" "$(echo "$R" | json "['ingresos_mes'].__float__()")"

rm -f /tmp/ck_* /tmp/cancion.mp3 /tmp/portada.jpg /tmp/logo.png /tmp/pago.jpg
echo ""
if [ "$FALLOS" -eq 0 ]; then echo "TODO OK (0 fallos)"; else echo "HAY $FALLOS FALLO(S)"; fi
exit $FALLOS
