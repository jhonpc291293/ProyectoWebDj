// Prueba de punta a punta del panel (web/admin.html) con un navegador real,
// contra el servidor PHP + MySQL de prueba en http://127.0.0.1:8099.
// Requiere: npm i playwright, y los datos sembrados antes (ver el bloque de
// arranque en el commit): admin, un miembro con un pago y una compra
// pendientes, y el track del admin "t-admin" + "t-venta" a la venta.
const { chromium, request } = require('playwright');
const { execSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const BASE = 'http://127.0.0.1:8099/';
const env = { ...process.env, MSYS_NO_PATHCONV: '1' };
// utf8mb4 para que las tildes se lean bien; y las consultas no llevan tildes
// adentro (la consola de Windows las cambia al pasarlas como argumento)
const sql = q => execSync(`docker exec vpm-mysql-test mysql -uroot -ptest1234 vip_paita_mix --default-character-set=utf8mb4 -N -e "${q}"`,
  { env, stdio: ['ignore', 'pipe', 'ignore'] }).toString('utf8').trim();
const existe = ruta => { try { execSync(`docker exec vpm-php-test test -f ${ruta}`, { env, stdio: 'ignore' }); return 'si'; } catch { return 'no'; } };

let fallos = 0;
function verificar(titulo, esperado, obtenido) {
  const ok = String(esperado) === String(obtenido);
  console.log(`${ok ? 'OK   ' : 'FALLO'} - ${titulo}${ok ? '' : ` (esperado=${esperado}, obtuvo=${obtenido})`}`);
  if (!ok) fallos++;
}
// espera a que una consulta SQL dé el valor esperado (las acciones son asíncronas)
async function esperarSQL(q, esperado, ms = 6000) {
  const fin = Date.now() + ms; let v;
  while (Date.now() < fin) { v = sql(q); if (v === String(esperado)) return v; await new Promise(r => setTimeout(r, 200)); }
  return v;
}

(async () => {
  const tmp = os.tmpdir();
  const portada = path.join(tmp, 'portada-test.jpg'); fs.writeFileSync(portada, 'imagen de portada');
  const cancion = path.join(tmp, 'cancion-test.mp3'); fs.writeFileSync(cancion, 'audio completo de prueba');

  const browser = await chromium.launch();
  const errores = [];
  async function abrirPanel(email, clave) {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    page.on('pageerror', e => errores.push(`${email}: ${e.message}`));
    page.on('dialog', d => d.dismiss());
    await page.goto(BASE + 'admin.html', { waitUntil: 'load' });
    await page.waitForSelector('#gateLogin:not(.hide)');
    await page.fill('#lgMail', email);
    await page.fill('#lgPass', clave);
    await page.click('#lgBtn');
    await page.waitForSelector('#app:not(.hide)');
    await page.waitForSelector('#view .kpis, #view .card');
    return { ctx, page };
  }
  const ir = async (page, vista) => { await page.click(`#menu button[data-v="${vista}"]`); await page.waitForTimeout(400); };
  const boton = (page, texto) => page.locator('#mFoot button', { hasText: texto });

  // =================== ADMIN ===================
  const { page: a } = await abrirPanel('admin@test.com', 'claveadmin');
  console.log('=== Admin: entrada ===');
  verificar('entra como Administrador', true, (await a.textContent('#who')).includes('Administrador'));
  verificar('ve el menú completo (Pagos por aprobar)', 1, await a.locator('#menu button[data-v="pagos"]').count());
  verificar('el aviso de pagos pendientes marca 1', '1', (await a.textContent('#pillPagos')).trim());
  verificar('el resumen muestra 1 pago por aprobar', '1', (await a.locator('.kpi.c1 b').textContent()).trim());

  console.log('\n=== Admin: pagos ===');
  await ir(a, 'pagos');
  const rutaComp = sql('SELECT comprobante FROM memberships LIMIT 1');
  const resp = await a.request.get(BASE + 'ver_comprobante.php?ruta=' + encodeURIComponent(rutaComp));
  verificar('el admin puede abrir la captura del pago', 200, resp.status());
  await a.locator('#view [data-ok]').first().click();
  verificar('aprobar activa la membresía', 'activa', await esperarSQL('SELECT estado FROM memberships LIMIT 1', 'activa'));
  await a.waitForFunction(() => document.querySelector('#mTitle').textContent === 'Membresía activada');
  verificar('ofrece avisar por WhatsApp al miembro', 'Membresía activada', await a.textContent('#mTitle'));
  await boton(a, 'Cerrar').click();

  console.log('\n=== Admin: compras sueltas ===');
  await ir(a, 'compras');
  verificar('la compra muestra el título de la canción', true, (await a.textContent('#view')).includes('A la venta'));
  await a.locator('#view [data-ok]').first().click();
  verificar('aprobar la compra la deja aprobada', 'aprobada', await esperarSQL('SELECT estado FROM compras LIMIT 1', 'aprobada'));
  await a.waitForTimeout(400); await boton(a, 'Cerrar').click().catch(() => {});

  console.log('\n=== Admin: subir un track ===');
  await ir(a, 'tracks');
  await a.click('#nuevo');
  await a.fill('#mBody [name="titulo"]', 'Track Nuevo Admin');
  await a.fill('#mBody [name="genero"]', 'Cumbia');
  await a.setInputFiles('#arch-portada', portada);
  await a.waitForFunction(() => document.querySelector('[data-url="portada"]').textContent.includes('portada-test'));
  await a.setInputFiles('#arch-_archivo', cancion);
  await a.waitForFunction(() => document.querySelector('[data-url="_archivo"]').textContent.includes('cancion-test'));
  await boton(a, 'Publicar').click();
  const idNuevo = await esperarSQL("SELECT COUNT(*) FROM tracks WHERE titulo='Track Nuevo Admin'", '1') === '1'
    ? sql("SELECT id FROM tracks WHERE titulo='Track Nuevo Admin'") : '';
  verificar('el track quedó publicado', true, idNuevo.length > 0);
  const portadaUrl = sql(`SELECT portada FROM tracks WHERE id='${idNuevo}'`);
  const rutaFull = sql(`SELECT ruta FROM track_files WHERE track_id='${idNuevo}'`);
  verificar('la portada quedó en la carpeta pública', true, portadaUrl.startsWith('/subidas/portadas/'));
  verificar('el archivo completo quedó en la carpeta privada', true, rutaFull.startsWith('descargas/'));
  verificar('la portada se puede ver por la web', 200, (await a.request.get(BASE + portadaUrl.slice(1))).status());
  verificar('el archivo completo NO se puede bajar por URL directa', 404, (await a.request.get(BASE + rutaFull)).status());

  await a.waitForSelector(`#view [data-edit="${idNuevo}"]`);
  await a.click(`#view [data-edit="${idNuevo}"]`);
  await a.fill('#mBody [name="titulo"]', 'Track Nuevo Admin (editado)');
  await boton(a, 'Guardar').click();
  verificar('editar el track guarda el cambio', 'Track Nuevo Admin (editado)',
    await esperarSQL(`SELECT titulo FROM tracks WHERE id='${idNuevo}'`, 'Track Nuevo Admin (editado)'));
  verificar('editar no pierde el archivo completo', rutaFull, sql(`SELECT ruta FROM track_files WHERE track_id='${idNuevo}'`));

  console.log('\n=== Admin: cuentas ===');
  await ir(a, 'editores');
  await a.click('#nuevaCuenta');
  await a.fill('#mBody [name="nombre"]', 'DJ Nuevo');
  await a.fill('#mBody [name="email"]', 'dj.nuevo@test.com');
  await a.fill('#mBody [name="password"]', 'clavedj1');
  await boton(a, 'Crear cuenta').click();
  verificar('crea la cuenta de editor', 'editor', await esperarSQL("SELECT rol FROM usuarios WHERE email='dj.nuevo@test.com'", 'editor'));

  await ir(a, 'miembros');
  verificar('el miembro aparece con su membresía activa', true, (await a.textContent('#view')).includes('activa'));
  await a.locator('#view [data-clave-miembro]').first().click();
  await a.fill('#mBody [name="clave"]', 'clavenueva9');
  await boton(a, 'Restablecer').click();
  await a.waitForFunction(() => document.querySelector('#mTitle').textContent === 'Contraseña restablecida');
  await boton(a, 'Cerrar').click();
  // desde una conexión aparte: si se hiciera con la del admin, la sesión del
  // admin quedaría reemplazada por la del miembro
  const otra = await request.newContext();
  const login = await otra.post(BASE + 'api/publica.php?accion=login',
    { headers: { 'X-VPM': '1' }, multipart: { email: 'socio@test.com', password: 'clavenueva9' } });
  verificar('el miembro entra con la clave que le puso el admin', true, (await login.json()).ok);
  await otra.dispose();

  console.log('\n=== Admin: planes, crew, comunicados, marca, mensajes ===');
  await ir(a, 'plans');
  await a.click('#nuevo');
  await a.fill('#mBody [name="nombre"]', 'VIP Oro');
  await a.fill('#mBody [name="dias"]', '60');
  await a.fill('#mBody [name="precio"]', '75');
  await a.fill('#mBody [name="beneficios"]', 'Todo el catálogo\nPedidos a medida');
  await boton(a, 'Crear').click();
  verificar('crea el plan', '75.00', await esperarSQL("SELECT precio FROM planes WHERE nombre='VIP Oro'", '75.00'));
  verificar('con sus beneficios', '["Todo el catálogo", "Pedidos a medida"]', sql("SELECT beneficios FROM planes WHERE nombre='VIP Oro'"));
  const ordenAntes = sql("SELECT orden FROM planes WHERE nombre='VIP Oro'");
  await a.waitForTimeout(500);
  await a.locator('#view [data-sube]').last().click();
  verificar('subir el plan en el orden', String(+ordenAntes - 1), await esperarSQL("SELECT orden FROM planes WHERE nombre='VIP Oro'", String(+ordenAntes - 1)));

  await ir(a, 'crew');
  await a.click('#nuevo');
  await a.fill('#mBody [name="alias"]', 'DJ Invitado Nuevo');
  await boton(a, 'Crear').click();
  verificar('agrega un integrante al crew', '1', await esperarSQL("SELECT COUNT(*) FROM crew WHERE alias='DJ Invitado Nuevo'", '1'));

  await ir(a, 'comunicados');
  await a.click('#nuevo');
  await a.fill('#mBody [name="titulo"]', 'Llegó el pack de Navidad');
  await boton(a, 'Publicar').click();
  verificar('publica el comunicado, firmado por el admin', 'Ronald',
    await esperarSQL("SELECT autor FROM comunicados WHERE titulo LIKE 'Lleg%pack de Navidad'", 'Ronald'));
  verificar('el título se guarda con su tilde', 'Llegó el pack de Navidad', sql("SELECT titulo FROM comunicados WHERE titulo LIKE 'Lleg%Navidad'"));

  await ir(a, 'settings');
  await a.fill('#formM [name="marca"]', 'VIP PAITA MIX PRO');
  await a.click('#save');
  verificar('guarda el nombre de la marca', 'VIP PAITA MIX PRO', await esperarSQL('SELECT marca FROM settings', 'VIP PAITA MIX PRO'));

  await ir(a, 'mensajes');
  await a.selectOption('#view [data-eb]', 'cotizado');
  verificar('cambia el estado de un mensaje', 'cotizado', await esperarSQL('SELECT estado FROM bookings', 'cotizado'));

  // =================== EDITOR ===================
  console.log('\n=== Editor: solo lo suyo ===');
  const { page: e } = await abrirPanel('dj.nuevo@test.com', 'clavedj1');
  verificar('entra como DJ editor', true, (await e.textContent('#who')).includes('DJ editor'));
  verificar('no ve "Pagos por aprobar"', 0, await e.locator('#menu button[data-v="pagos"]').count());
  verificar('no ve "Marca y contacto"', 0, await e.locator('#menu button[data-v="settings"]').count());
  const directo = await e.evaluate(async () => (await fetch('api/panel.php?accion=membresias', { credentials: 'same-origin' })).status);
  verificar('si intenta pedir los pagos a mano al servidor, recibe 403', 403, directo);

  await ir(e, 'tracks');
  verificar('no ve los tracks del admin', false, (await e.textContent('#view')).includes('Track Nuevo Admin'));
  await e.click('#nuevo');
  verificar('el formulario no le deja elegir otro DJ', 0, await e.locator('#mBody [name="editor_id"]').count());
  await e.fill('#mBody [name="titulo"]', 'Edit del DJ Nuevo');
  await boton(e, 'Publicar').click();
  const editorId = sql("SELECT id FROM usuarios WHERE email='dj.nuevo@test.com'");
  verificar('su track queda a su nombre', editorId, await esperarSQL("SELECT editor_id FROM tracks WHERE titulo='Edit del DJ Nuevo'", editorId));
  await e.waitForTimeout(500);
  verificar('ve su propio track en la lista', true, (await e.textContent('#view')).includes('Edit del DJ Nuevo'));

  await ir(e, 'comunicados');
  verificar('ve el comunicado del admin pero sin poder editarlo', true, (await e.textContent('#view')).includes('solo su autor'));

  // =================== ADMIN: borrar ===================
  console.log('\n=== Admin: borrar un track borra sus archivos ===');
  await ir(a, 'tracks');
  await a.waitForSelector(`#view [data-del="${idNuevo}"]`);
  await a.click(`#view [data-del="${idNuevo}"]`);
  await boton(a, 'Sí, borrar').click();
  verificar('el track desaparece', '0', await esperarSQL(`SELECT COUNT(*) FROM tracks WHERE id='${idNuevo}'`, '0'));
  verificar('su portada se borró del servidor', 'no', existe('/app/web' + portadaUrl));
  verificar('su archivo completo se borró del servidor', 'no', existe('/app/privado/' + rutaFull));

  verificar('ningún error de JavaScript en todo el recorrido', '[]', JSON.stringify(errores));
  await browser.close();
  fs.unlinkSync(portada); fs.unlinkSync(cancion);
  console.log('\n' + (fallos === 0 ? 'TODO OK (0 fallos)' : `HAY ${fallos} FALLO(S)`));
  process.exit(fallos ? 1 : 0);
})().catch(e => { console.error('FALLÓ:', e); process.exit(1); });
