/* ============================================================================
   CONEXIÓN A SUPABASE — el único archivo con datos de configuración.
   Lo llenas UNA vez y no lo vuelves a tocar.

   Dónde saco estos dos valores:

   Opción rápida — botón verde "Connect" arriba en el panel de Supabase:
     muestra el Project URL y la clave lista para copiar.

   Opción por menú — Supabase → Settings → API Keys:
     · Project URL                        →  url
     · Publishable key (sb_publishable_…) →  anon
       (o la clave "anon" clásica, que empieza con eyJ… ; las dos funcionan)

   Esa clave es pública a propósito: solo puede hacer lo que permiten las
   políticas de seguridad (leer el contenido visible y crear pedidos).
   NUNCA pongas aquí la clave "secret" ni la "service_role".
   ============================================================================ */

window.SUPA = {
  url : "https://ezyjycixgmazdlbqfvqr.supabase.co",   // ej: "https://abcdefghijkl.supabase.co"
  anon: "sb_publishable_G6-ExuOFQpdPhSSVJX4G_w_riDjWGqs"    // ej: "sb_publishable_AbCd1234..."  o  "eyJhbGciOiJIUzI1NiIs..."
};
