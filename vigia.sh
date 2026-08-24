#!/bin/bash
# ============================================================================
#  VIGÍA EXTERNO DEL MAC MINI — la lógica
#  Lo invoca .github/workflows/vigia.yml cada 20 min desde GitHub Actions.
#
#  Vive como script aparte (y no dentro del YAML) porque el token de gh no
#  tiene el scope `workflow`: los .yml de workflow hay que crearlos desde la
#  web. Además así se puede probar en local:
#      GIST_ID=... GIST_TOKEN=... TELEGRAM_TOKEN=... TELEGRAM_CHAT_ID=... \
#        bash vigia.sh
# ============================================================================
set -uo pipefail

UMBRAL=2700       # 45 min sin latido = problema (el mini late cada 10)
# ESPERADOS ya NO vive aquí (23-AGO-2026). Lo publica el mini en el propio latido.
# La nota del 10-AGO que había en esta línea diagnosticó el problema y aplicó el parche
# equivocado: subió 25 → 30 «porque un umbral que envejece se vuelve un permiso», y trece
# días después había vuelto a envejecer (54 agentes reales ⇒ 30 toleraba perder 24).
# La causa de que el número tuviera que ser TAN BAJO era no poder distinguir «19 agentes
# parados porque no hay sesión gráfica» de «19 caídos por avería». Ahora el mini publica
# `sesion` y descuenta él mismo los de sesión cuando no la hay, así que el vigía puede
# exigir el número exacto en vez de un mínimo generoso.
ESPERADOS_FALLBACK=30   # solo si el latido es viejo y no trae el campo
TOLERANCIA=2       # 24-AGO: baja de 4 a 2. El emisor ya descuenta los kill-switch
                   # (state/overlays_off apaga overlay y briefoverlay desde el 05-AGO), así
                   # que esos dos dejaron de contar como avería. Quedan `brave-cdp` y
                   # `funda-ws`, pendientes de decidir si se jubilan o se cargan.
                   # ⚠️ SIGUE SIENDO DEUDA: con 2, una avería de hasta 2 agentes pasa
                   # desapercibida. Solo llega a 0 resolviendo esos dos — NUNCA subiendo
                   # esto para acallar un aviso.
RECORDAR=21600    # si sigue caído, repetir el aviso cada 6 h
PING=604800       # señal de vida propia una vez por semana

avisar() {
  [ -n "${TELEGRAM_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || {
    echo "::error::faltan credenciales de Telegram"; return 1; }
  curl -s --max-time 20 \
    "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
    --data-urlencode "text=$1" > /dev/null
}

# Los mensajes se arman con \n explícitos y NO con saltos de línea
# reales: dentro de un bloque `run: |` de YAML, una línea que empiece
# en la columna 0 CIERRA el bloque y parte el script en dos. Se
# detectó al validar la sintaxis antes de publicar.
NL=$'\n'

# --- leer el latido del gist -------------------------------------
# Se captura el CÓDIGO HTTP, no solo el cuerpo, porque "no pude leer el
# gist" son en realidad dos casos muy distintos y tratarlos igual dejaba
# al vigía mudo para siempre:
#   · red caída / 5xx  → el problema es de AQUÍ, no del mini → callar.
#     Un vigía que avisa en falso deja de leerse.
#   · 401/403/404      → el token falta, se revocó o el gist ya no está.
#     Eso NO es "GitHub está caído": es EL VIGÍA ROTO, y hay que gritarlo.
#     Antes caía en el mismo `exit 0` silencioso y ni siquiera llegaba al
#     ping semanal, así que la avería se tragaba también a su propio canario.
RESPUESTA=$(curl -s --max-time 25 -w '\n%{http_code}' \
  -H "Authorization: Bearer ${GIST_TOKEN:-}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/gists/${GIST_ID:-}" 2>/dev/null)
CODIGO=$(printf '%s' "$RESPUESTA" | tail -1)
CUERPO=$(printf '%s' "$RESPUESTA" | sed '$d')

PROBLEMA=""
MIN=0
AGENTES="?"

case "$CODIGO" in
  200)
    CONTENIDO=$(printf '%s' "$CUERPO" | python3 -c \
      "import sys,json; print(json.load(sys.stdin)['files']['latido.txt']['content'])" 2>/dev/null)
    if [ -z "$CONTENIDO" ]; then
      echo "el gist responde pero no trae latido.txt legible"; exit 0
    fi
    EPOCH=$(printf '%s\n' "$CONTENIDO" | sed -n 's/^epoch=//p' | tr -d '[:space:]')
    AGENTES=$(printf '%s\n' "$CONTENIDO" | sed -n 's/^agentes=//p' | tr -d '[:space:]')
    # Campos añadidos el 23-AGO. Si el latido es de antes, quedan vacíos y se cae al
    # fallback: un vigía no debe romperse porque el emisor sea de otra versión.
    ESPERADOS=$(printf '%s\n' "$CONTENIDO" | sed -n 's/^esperados=//p' | tr -d '[:space:]')
    SESION=$(printf '%s\n' "$CONTENIDO" | sed -n 's/^sesion=//p' | tr -d '[:space:]')
    printf '%s' "$ESPERADOS" | grep -qE '^[1-9][0-9]*$' || ESPERADOS=$ESPERADOS_FALLBACK
    case "$EPOCH" in ''|*[!0-9]*) echo "latido ilegible"; exit 0 ;; esac
    AHORA_TMP=$(date +%s)
    EDAD=$(( AHORA_TMP - EPOCH ))
    MIN=$(( EDAD / 60 ))
    if [ "$EDAD" -gt "$UMBRAL" ]; then
      PROBLEMA="🔴 EL MINI NO DA SEÑALES desde hace $MIN min.  [vigía externo]${NL}${NL}Los recordatorios de WhatsApp, las confirmaciones y el calendar-sync están PARADOS.${NL}${NL}Causa más probable: se reinició y está en la pantalla de FileVault. Los agentes no arrancan hasta que alguien desbloquee la sesión a mano.${NL}${NL}Qué hacer: ir al mini, desbloquear, y comprobar que salgan 25 o más con:${NL}  launchctl list | grep -cE 'com\.(kronos|odontocloud)\.'"
    elif printf '%s' "$AGENTES" | grep -qE '^[0-9]+$' && [ "$AGENTES" -lt "$(( ESPERADOS - TOLERANCIA ))" ]; then
      if [ "${SESION:-}" = "0" ]; then
        PISTA="El mini dice que NO tiene sesión gráfica: lo más probable es que se reiniciara y esté en la pantalla de FileVault. Los ~21 agentes de sesión no arrancan hasta desbloquear a mano."
      else
        PISTA="El mini SÍ tiene sesión gráfica, así que no es FileVault: alguno se cayó de verdad."
      fi
      PROBLEMA="🟡 El mini responde, pero solo tiene $AGENTES de $ESPERADOS agentes cargados.  [vigía externo]${NL}${NL}${PISTA}${NL}${NL}Revisar allá con:${NL}  launchctl list | grep -E 'com\.(kronos|odontocloud)\.'"
    fi
    ;;
  401|403|404)
    PROBLEMA="🟠 EL VIGÍA ESTÁ CIEGO — GitHub respondió $CODIGO al leer el gist.  [vigía externo]${NL}${NL}Esto NO dice nada del mini: dice que el vigía no puede mirarlo. Mientras siga así, que no lleguen alertas NO significa que producción esté bien.${NL}${NL}Causas: el secret GIST_TOKEN falta, caducó o se revocó (404 = además el gist pudo borrarse).${NL}${NL}Arreglo: regenerar el token con scope 'gist' y actualizarlo en Settings → Secrets and variables → Actions."
    ;;
  *)
    # 000 (sin red), 5xx, timeouts. Transitorio y ajeno al mini → silencio.
    echo "GitHub no contestó (código '$CODIGO') — no se concluye nada"
    exit 0
    ;;
esac

# --- máquina de estados: avisar en el cambio, no en cada pasada ---
AHORA=$(date +%s)
ANTERIOR=$(cat estado/ultimo.txt 2>/dev/null | head -1)
ULTIMO=$(cat estado/ultimo.txt 2>/dev/null | sed -n '2p')
case "${ULTIMO:-}" in ''|*[!0-9]*) ULTIMO=0 ;; esac
: "${ANTERIOR:=OK}"

CAMBIO=0
if [ -n "$PROBLEMA" ]; then
  if [ "$ANTERIOR" != "ALERTA" ] || [ $(( AHORA - ULTIMO )) -gt "$RECORDAR" ]; then
    avisar "$PROBLEMA" && echo "aviso enviado (http=$CODIGO edad=${MIN}m agentes=$AGENTES)"
    printf 'ALERTA\n%s\n' "$AHORA" > estado/ultimo.txt; CAMBIO=1
  else
    echo "sigue en alerta (http=$CODIGO edad=${MIN}m) — ya avisado, en silencio"
  fi
else
  if [ "$ANTERIOR" = "ALERTA" ]; then
    avisar "🟢 El mini volvió. $AGENTES agentes cargados, último latido hace $MIN min.  [vigía externo]"
    CAMBIO=1
  fi
  printf 'OK\n%s\n' "$AHORA" > estado/ultimo.txt
  echo "OK (edad=${MIN}m agentes=$AGENTES/${ESPERADOS:-?} sesion=${SESION:-?})"
fi

# --- señal de vida del propio vigía, una vez por semana ----------
# GitHub DESACTIVA los workflows programados tras 60 días sin actividad
# en el repo. Este ping cumple DOS funciones, no una:
#   · canario — si deja de llegar, el vigía dejó de correr;
#   · vacuna  — al escribir estado/ultimo_ping.txt dispara CAMBIO=1, y el
#     paso "Guardar el estado" del workflow hace commit. Ese commit ES
#     actividad del repo, así que reinicia el contador de 60 días cada
#     semana y el workflow no llega a desactivarse nunca.
# Solo se manda si de verdad leímos el gist (código 200): un "estoy vivo"
# emitido mientras el vigía está ciego sería exactamente la clase de
# tranquilidad falsa que este archivo existe para evitar.
if [ "$CODIGO" = "200" ]; then
  ULTIMO_PING=$(cat estado/ultimo_ping.txt 2>/dev/null | tr -d '[:space:]')
  case "${ULTIMO_PING:-}" in ''|*[!0-9]*) ULTIMO_PING=0 ;; esac
  if [ $(( AHORA - ULTIMO_PING )) -gt "$PING" ]; then
    avisar "🔵 Vigía externo del mini: vivo. Último latido hace $MIN min, $AGENTES agentes.${NL}(este mensaje llega una vez por semana; si deja de llegar, el vigía se apagó)"
    printf '%s\n' "$AHORA" > estado/ultimo_ping.txt; CAMBIO=1
  fi
fi

echo "CAMBIO=$CAMBIO" >> "${GITHUB_ENV:-/dev/null}"
