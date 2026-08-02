# Vigía externo del Mac mini

Comprueba cada 20 minutos que el Mac mini sigue vivo y avisa por Telegram si no.

## Por qué

El mini es el punto fijo de la casa: corre KRONOS y los 13 agentes de producción
de OdontoCloud — recordatorios de WhatsApp a pacientes, confirmaciones de citas,
calendar-sync y los respaldos de la base de datos.

Si se cae, con FileVault activo se queda en la pantalla de desbloqueo y **ningún
agente arranca**. En silencio. Los vigías que viven dentro del mini
(`backup-guard`, `calendar-sync-guard`) se callan junto con él, porque corren ahí.

Ya hay un vigía local en el MacBook Pro 2018 (`com.vigia.mini`), pero ese equipo
es un portátil que duerme: puede estar dormido justo cuando el mini se cae. Este
workflow mira desde fuera y no duerme nunca. Los dos conviven a propósito.

## Cómo funciona

El mini publica un latido cada 10 minutos en un gist secreto:

```
epoch=1785...
agentes=25
```

Este workflow lo lee y avisa por Telegram si:

| Condición | Aviso |
|---|---|
| Latido con más de **45 min** | 🔴 el mini no da señales |
| Menos de **25 agentes** cargados | 🟡 se cayó alguno |
| Vuelve tras una alerta | 🟢 recuperado |
| Una vez por semana | 🔵 el vigía sigue vivo |

Avisa **en el cambio de estado**, no en cada pasada. Si sigue caído, repite el
aviso cada 6 horas. Si GitHub no contesta, se calla: el problema sería de aquí,
no del mini, y un vigía que avisa en falso deja de leerse.

## El ping semanal no es decorativo

GitHub **desactiva los workflows programados tras 60 días sin actividad en el
repositorio**. Si eso ocurre, este vigía muere sin decir nada — exactamente el
fallo que vino a evitar.

Por eso manda una señal de vida semanal. **Si dejas de recibir el 🔵, el vigía se
apagó**: entra a la pestaña *Actions* y reactívalo.

## Secrets necesarios

| Secret | Qué es |
|---|---|
| `GIST_ID` | id del gist donde el mini publica el latido |
| `GIST_TOKEN` | token clásico con **solo** el scope `gist` (el gist es secreto) |
| `TELEGRAM_TOKEN` | token del bot |
| `TELEGRAM_CHAT_ID` | chat de destino |

El repositorio es público para tener minutos de Actions ilimitados (en privado el
plan Free da 2.000/mes y un chequeo cada 20 min se pasa). No contiene ningún dato
sensible: todo va en Secrets, que no son públicos.

## Probarlo

Pestaña **Actions → Vigía del Mac mini → Run workflow**.
