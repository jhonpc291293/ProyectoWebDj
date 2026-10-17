#!/bin/bash
# Prueba la API pública (web/api/publica.php) contra un servidor PHP real.
# Requiere: contenedores vpm-mysql-test (con schema.sql) y vpm-php-test
# corriendo, y los tracks de prueba sembrados (ver el bloque SQL abajo).
BASE="http://127.0.0.1:8099/api/publica.php"
H="X-VPM: 1"
FALLOS=0
verificar() {
  if [ "$2" = "$3" ]; then echo "OK    - $1"; else echo "FALLO - $1 (esperado=$2, obtuvo=$3)"; FALLOS=$((FALLOS+1)); fi
}
json() { python -c "import sys,json; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1"; }
sql() { docker exec vpm-mysql-test mysql -uroot -ptest1234 vip_paita_mix -N -e "$1" 2>/dev/null; }

rm -f /tmp/ck_adm /tmp/ck_mem /tmp/ck_otro
echo "comprobante de prueba" > /tmp/pago.jpg

echo "=== Contenido público ==="
R=$(curl -s "$BASE?accion=inicio")
verificar "inicio responde ok" "True" "$(echo "$R" | json "['ok']")"
verificar "trae los 4 planes" "4" "$(echo "$R" | json "['planes'].__len__()")"
verificar "trae los 3 tracks visibles (el oculto no)" "3" "$(echo "$R" | json "['tracks'].__len__()")"
verificar "no publica el correo interno del editor" "False" "$(echo "$R" | json "['tracks'][0].__contains__('editor_email')")"
verificar "los JSON llegan como listas, no como texto" "list" "$(echo "$R" | json "['planes'][0]['beneficios'].__class__.__name__")"

echo ""
echo "=== Registro y login ==="
CODE=$(curl -s -o /dev/null -w "%{http_code}" -d "email=a@b.com&password=123456&nombre=X" "$BASE?accion=registrar")
verificar "un POST sin la cabecera X-VPM se rechaza (anti-CSRF)" "403" "$CODE"

R=$(curl -s -c /tmp/ck_adm -H "$H" -d "email=admin@test.com&password=claveadmin&nombre=Ronald" "$BASE?accion=registrar")
verificar "el primer registro queda admin" "admin" "$(echo "$R" | json "['usuario']['rol']")"

R=$(curl -s -c /tmp/ck_mem -H "$H" -d "email=cliente@test.com&password=clave123&nombre=Cliente&telefono=999 888 777" "$BASE?accion=registrar")
verificar "el siguiente registro queda member" "member" "$(echo "$R" | json "['usuario']['rol']")"
verificar "el registro ya deja la sesión iniciada" "cliente@test.com" "$(curl -s -b /tmp/ck_mem "$BASE?accion=sesion" | json "['usuario']['email']")"
verificar "el teléfono se guarda solo con dígitos" "999888777" "$(sql "SELECT telefono FROM usuarios WHERE email='cliente@test.com'")"

CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "$H" -d "email=cliente@test.com&password=mala" "$BASE?accion=login")
verificar "login con clave incorrecta -> 401" "401" "$CODE"

verificar "sin sesión, 'sesion' devuelve usuario null" "None" "$(curl -s "$BASE?accion=sesion" | json "['usuario']")"

CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE?accion=mi_cuenta")
verificar "mi_cuenta sin sesión -> 403" "403" "$CODE"

R=$(curl -s -H "$H" -d "email=noexiste@test.com" "$BASE?accion=olvide")
verificar "'olvidé mi clave' no revela si el correo existe" "True" "$(echo "$R" | json "['ok']")"
verificar "y nunca devuelve el token en la respuesta" "False" "$(echo "$R" | json ".__contains__('token')")"

echo ""
echo "=== Pedir membresía ==="
PLAN=$(sql "SELECT id FROM planes WHERE nombre='Mensual'")
R=$(curl -s -b /tmp/ck_mem -H "$H" -F "plan_id=$PLAN" -F "comprobante=@/tmp/pago.jpg" "$BASE?accion=solicitar_membresia")
verificar "solicitar_membresia con comprobante -> ok" "True" "$(echo "$R" | json "['ok']")"
verificar "queda como 'pendiente' (no se activa sola)" "pendiente" "$(sql "SELECT estado FROM memberships WHERE monto=40")"
MID=$(sql "SELECT id FROM usuarios WHERE email='cliente@test.com'")
RUTA=$(sql "SELECT comprobante FROM memberships WHERE user_id='$MID'")
verificar "el comprobante va a la subcarpeta del propio usuario" "comprobantes/$MID/" "$(echo "$RUTA" | grep -o "comprobantes/$MID/")"

CODE=$(curl -s -o /dev/null -w "%{http_code}" -b /tmp/ck_mem "http://127.0.0.1:8099/ver_comprobante.php?ruta=$RUTA")
verificar "el cliente puede ver su propio comprobante recién subido" "200" "$CODE"

R=$(curl -s -b /tmp/ck_mem "$BASE?accion=mi_cuenta")
verificar "mi_cuenta muestra la membresía pendiente" "pendiente" "$(echo "$R" | json "['membresia']['estado']")"
verificar "mientras está pendiente no puede descargar el track normal" "False" "$(echo "$R" | json "['descargables'].__contains__('t-normal')")"
verificar "pero sí el gratis" "True" "$(echo "$R" | json "['descargables'].__contains__('t-gratis')")"

echo ""
echo "=== Compra suelta ==="
R=$(curl -s -b /tmp/ck_mem -H "$H" -F "track_ids=t-venta" -F "monto=0.01" -F "comprobante=@/tmp/pago.jpg" "$BASE?accion=solicitar_compra")
verificar "el total sale del precio de la base de datos, no del navegador" "5.0" "$(echo "$R" | json "['total'].__float__()")"
verificar "la línea de compra guarda el precio del momento" "5.00" "$(sql "SELECT precio FROM compra_tracks WHERE track_id='t-venta'")"

CODE=$(curl -s -o /dev/null -w "%{http_code}" -b /tmp/ck_mem -H "$H" -F "track_ids=t-normal" -F "comprobante=@/tmp/pago.jpg" "$BASE?accion=solicitar_compra")
verificar "no deja 'comprar' un track que no está a la venta" "400" "$CODE"

echo ""
echo "=== El admin aprueba y el acceso se abre ==="
docker exec vpm-mysql-test mysql -uroot -ptest1234 vip_paita_mix -e "UPDATE memberships SET estado='activa', inicio=CURDATE(), fin=DATE_ADD(CURDATE(), INTERVAL 30 DAY)" 2>/dev/null
R=$(curl -s -b /tmp/ck_mem "$BASE?accion=mi_cuenta")
verificar "con la membresía activa, ya puede descargar el track normal" "True" "$(echo "$R" | json "['descargables'].__contains__('t-normal')")"
verificar "y mi_membresia reporta 'activa'" "activa" "$(echo "$R" | json "['membresia']['estado']")"

echo ""
echo "=== Otros ==="
R=$(curl -s -H "$H" -d "nombre=Fiesta&email=x@y.com&tipo=Matrimonio&fecha=2026-12-20&lugar=Paita&mensaje=Hola" "$BASE?accion=booking")
verificar "un visitante sin cuenta puede mandar una solicitud de booking" "True" "$(echo "$R" | json "['ok']")"

CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE?accion=inventada")
verificar "una acción desconocida -> 404" "404" "$CODE"

curl -s -b /tmp/ck_mem -c /tmp/ck_mem -H "$H" -X POST "$BASE?accion=logout" >/dev/null
verificar "tras logout, la sesión queda vacía" "None" "$(curl -s -b /tmp/ck_mem "$BASE?accion=sesion" | json "['usuario']")"

rm -f /tmp/ck_adm /tmp/ck_mem /tmp/ck_otro /tmp/pago.jpg
echo ""
if [ "$FALLOS" -eq 0 ]; then echo "TODO OK (0 fallos)"; else echo "HAY $FALLOS FALLO(S)"; fi
exit $FALLOS
