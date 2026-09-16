// ============================================================================
// Crea una cuenta de acceso (Auth) directamente desde el panel de administración,
// sin que el admin tenga que entrar al dashboard de Supabase.
//
// Solo puede llamarla un usuario ya logueado con rol "admin": esta función usa
// la clave service_role (nunca expuesta al navegador) para crear el usuario y,
// si hace falta, fijarle el rol de una vez.
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  try {
    // 1) confirmar que quien llama es admin, usando SU propio token (respeta RLS)
    const authHeader = req.headers.get("Authorization") ?? "";
    const comoQuienLlama = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
    const { data: esAdmin, error: errRol } = await comoQuienLlama.rpc("es_admin");
    if (errRol || !esAdmin) return json({ error: "Solo el administrador puede realizar esta acción." }, 403);

    // 2) validar los datos del formulario
    const { accion, nombre, alias, telefono, email, password, rol, id } = await req.json();
    const admin = createClient(url, serviceKey);

    if (accion === "editar") {
      if (!id || !email || !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) {
        return json({ error: "Datos de miembro o correo no válidos." }, 400);
      }
      const { error: errAuth } = await admin.auth.admin.updateUserById(id, { email, email_confirm: true });
      if (errAuth) return json({ error: errAuth.message }, 400);
      const { error: errPerfil } = await admin.from("profiles").update({
        email, nombre: nombre || "", alias: alias || "", telefono: telefono || "",
      }).eq("id", id);
      if (errPerfil) return json({ error: errPerfil.message }, 400);
      return json({ id });
    }

    if (accion === "borrar") {
      if (!id || id === (await comoQuienLlama.auth.getUser()).data.user?.id) {
        return json({ error: "No puedes borrar tu propia cuenta desde aquí." }, 400);
      }
      const { error: errBorrar } = await admin.auth.admin.deleteUser(id);
      if (errBorrar) return json({ error: errBorrar.message }, 400);
      return json({ id });
    }
    if (!email || typeof email !== "string") return json({ error: "Falta el correo." }, 400);
    if (!password || String(password).length < 6) return json({ error: "La contraseña necesita 6 caracteres o más." }, 400);
    if (!["admin", "editor", "member"].includes(rol)) return json({ error: "Rol no válido." }, 400);

    // 3) crear el usuario con la clave de servicio (nunca sale de esta función)
    const { data: creado, error: errCrear } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { nombre: nombre || email.split("@")[0] },
    });
    if (errCrear) return json({ error: errCrear.message }, 400);

    // el trigger nuevo_perfil() ya creó el perfil como "member"; si pidieron otro rol, se fija aquí
    if (rol !== "member") {
      const { error: errFijarRol } = await admin.from("profiles").update({ rol }).eq("id", creado.user.id);
      if (errFijarRol) return json({ id: creado.user.id, aviso: "Cuenta creada, pero no se pudo fijar el rol: " + errFijarRol.message }, 207);
    }

    return json({ id: creado.user.id });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
