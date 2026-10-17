#!/bin/bash
# Pruebas contra el hosting REAL, solo por HTTP (sin Docker ni acceso a la
# base de datos). Las credenciales de la protección temporal del sitio se
# pasan al ejecutar, nunca se guardan aquí:
#   SITIO=http://vippaitamix.com AUTH='usuario:clave' bash test_en_vivo.sh
# Crea una cuenta de prueba (pruebas.<hora>@vippaitamix.com): la base de
# datos de prueba se vacía igual el día del cambio.
SITIO="${SITIO:-http://vippaitamix.com}"; PUB="$SITIO/api/publica.php"; H="X-VPM: 1"
[ -z "$AUTH" ] && { echo "Falta AUTH='usuario:clave'"; exit 1; }
FALLOS=0
export PYTHONIOENCODING=utf-8
verificar() {
  if [ "$2" = "$3" ]; then echo "OK    - $1"; else echo "FALLO - $1 (esperado=$2, obtuvo=$3)"; FALLOS=$((FALLOS+1)); fi
}
c() { curl -s --max-time 60 -u "$AUTH" "$@"; }
cod() { c -o /dev/null -w "%{http_code}" "$@"; }
json() { python -c "import sys,json; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1" 2>/dev/null || echo "(no-json)"; }
CK=$(mktemp); CORREO="pruebas.$(date +%H%M%S)@vippaitamix.com"

echo "=== Protección y archivos sensibles ==="
verificar "sin la clave temporal, el sitio no abre (401)" "401" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$SITIO/")"
verificar "con la clave temporal, la portada abre" "200" "$(cod "$SITIO/")"
verificar "el panel abre" "200" "$(cod "$SITIO/admin.html")"
verificar "config.php bloqueado (403)" "403" "$(cod "$SITIO/config.php")"
verificar ".htaccess bloqueado (403)" "403" "$(cod "$SITIO/.htaccess")"
verificar "auth.php no existe por URL (fuera de public_html)" "404" "$(cod "$SITIO/auth.php")"

echo ""
echo "=== La web lee la base de datos ==="
R=$(c "$PUB?accion=inicio")
verificar "la API responde ok" "True" "$(echo "$R" | json "['ok']")"
verificar "trae la marca desde la base" "VIP PAITA MIX" "$(echo "$R" | json "['settings']['marca']")"
verificar "trae los planes" "4" "$(echo "$R" | json "['planes'].__len__()")"

echo ""
echo "=== Cuenta nueva, sesión y cookie ==="
verificar "un POST sin la cabecera anti-CSRF se rechaza" "403" "$(cod -d "email=x@y.com&password=123456&nombre=X" "$PUB?accion=registrar")"
R=$(c -c "$CK" -H "$H" -d "email=$CORREO&password=ClavePrueba1&nombre=Pruebas Claude&telefono=900000000" "$PUB?accion=registrar")
verificar "se crea la cuenta de prueba" "True" "$(echo "$R" | json "['ok']")"
verificar "queda como miembro (no admin)" "member" "$(echo "$R" | json "['usuario']['rol']")"
verificar "la sesión queda abierta" "$CORREO" "$(c -b "$CK" "$PUB?accion=sesion" | json "['usuario']['email']")"
COOKIE=$(c -D - -o /dev/null -H "$H" -d "email=$CORREO&password=ClavePrueba1" "$PUB?accion=login" | grep -i '^set-cookie: vpm_sesion' | tail -1)
verificar "cookie de sesión HttpOnly (el JavaScript no la lee)" "1" "$(echo "$COOKIE" | grep -ci httponly)"
verificar "cookie de sesión SameSite=Lax" "1" "$(echo "$COOKIE" | grep -ci 'samesite=lax')"
verificar "clave equivocada no entra" "401" "$(cod -H "$H" -d "email=$CORREO&password=otra" "$PUB?accion=login")"

echo ""
echo "=== Pedir membresía con comprobante (subida real al servidor) ==="
PLAN=$(c "$PUB?accion=inicio" | json "['planes'][1]['id']")
printf 'captura de pago de prueba' > /tmp/pago-vivo.jpg
R=$(c -b "$CK" -H "$H" -F "plan_id=$PLAN" -F "comprobante=@/tmp/pago-vivo.jpg" "$PUB?accion=solicitar_membresia")
verificar "la solicitud con comprobante se registra" "True" "$(echo "$R" | json "['ok']")"
verificar "queda pendiente" "pendiente" "$(c -b "$CK" "$PUB?accion=mi_cuenta" | json "['membresia']['estado']")"
verificar "las fechas llegan con zona horaria de Lima" "-05:00" "$(c -b "$CK" "$PUB?accion=inicio" | json "['settings'].get('actualizado','')[-6:]")"

echo ""
echo "=== Contacto y salida ==="
verificar "el formulario de contacto guarda el mensaje" "True" "$(c -H "$H" -d "nombre=Prueba en vivo&email=$CORREO&mensaje=Mensaje de prueba del hosting" "$PUB?accion=booking" | json "['ok']")"
c -b "$CK" -c "$CK" -H "$H" -X POST "$PUB?accion=logout" >/dev/null
verificar "tras cerrar sesión, la sesión queda vacía" "None" "$(c -b "$CK" "$PUB?accion=sesion" | json "['usuario']")"

rm -f "$CK" /tmp/pago-vivo.jpg
echo ""
echo "Cuenta de prueba creada: $CORREO"
if [ "$FALLOS" -eq 0 ]; then echo "TODO OK (0 fallos)"; else echo "HAY $FALLOS FALLO(S)"; fi
exit $FALLOS
