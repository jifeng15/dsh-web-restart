/**
 * dsh-web-hot — host plugin for the dsh-web-restart skill.
 *
 * Registers same-origin HTTP endpoints on the webServer service:
 *   POST /dsh-web-hot/install    { spec }
 *   POST /dsh-web-hot/uninstall  { packageName }
 *   POST /dsh-web-hot/update     { packageName? }
 *   POST /dsh-web-hot/setEnabled { entryId, enabled }
 *   GET  /dsh-web-hot/list
 *
 * The bash half (dsh-web.sh) calls these to hot-install plugins without a
 * restart; it falls back to a safe restart when hot apply is unavailable.
 *
 * Follows the dsh-market host-plugin pattern: `apply` is the exported entry,
 * and `ctx.inject` receives the injected host ctx which carries webServer.
 */
import { fileURLToPath } from 'node:url'
import {
  installBundle,
  listBundles,
  setEnabled,
  uninstallBundle,
  updateBundle,
} from './manager.js'

/** Route prefix on the webServer. */
export const ROUTE_PREFIX = '/dsh-web-hot'

/** Cap on request body bytes. */
const BODY_LIMIT = 64 * 1024

async function readJson(req) {
  const chunks = []
  let size = 0
  for await (const chunk of req) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
    size += buffer.length
    if (size > BODY_LIMIT) throw new Error('request body too large')
    chunks.push(buffer)
  }
  const text = Buffer.concat(chunks).toString('utf8')
  if (text === '') return {}
  const parsed = JSON.parse(text)
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error('request body must be a JSON object')
  }
  return parsed
}

function send(res, status, value) {
  const body = JSON.stringify(value)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  })
  res.end(body)
}

function stringField(body, key) {
  const value = body[key]
  return typeof value === 'string' ? value : undefined
}

/**
 * Mount the dsh-web-hot HTTP routes on a host ctx that has webServer.
 * @param host - injected ctx carrying webServer.
 * @param profileDir - absolute profile directory for manager ops.
 */
function mountRoutes(host, profileDir) {
  const disposers = [
    host.webServer.register({
      kind: 'prefix',
      path: ROUTE_PREFIX,
      handler: async (req, res) => {
        const url = new URL(req.url ?? '/', 'http://x')
        const method = url.pathname.split('/').filter(Boolean)[1] ?? ''
        try {
          if (req.method === 'GET') {
            if (method === 'list') {
              send(res, 200, { ok: true, value: listBundles(profileDir) })
              return
            }
            send(res, 404, { ok: false, message: `unknown endpoint ${ROUTE_PREFIX}/${method}` })
            return
          }
          if (req.method !== 'POST') {
            send(res, 405, { ok: false, message: 'method not allowed' })
            return
          }
          const body = await readJson(req)
          switch (method) {
            case 'install': {
              const spec = stringField(body, 'spec')
              if (spec === undefined) {
                send(res, 400, { ok: false, message: 'spec is required' })
                return
              }
              send(res, 200, await installBundle(host, profileDir, spec))
              return
            }
            case 'uninstall': {
              const packageName = stringField(body, 'packageName')
              if (packageName === undefined) {
                send(res, 400, { ok: false, message: 'packageName is required' })
                return
              }
              send(res, 200, await uninstallBundle(host, profileDir, packageName))
              return
            }
            case 'update': {
              const packageName = stringField(body, 'packageName') ?? ''
              send(res, 200, await updateBundle(host, profileDir, packageName))
              return
            }
            case 'setEnabled': {
              const entryId = stringField(body, 'entryId')
              if (entryId === undefined || typeof body.enabled !== 'boolean') {
                send(res, 400, { ok: false, message: 'entryId and enabled are required' })
                return
              }
              send(res, 200, await setEnabled(host, profileDir, entryId, body.enabled))
              return
            }
            default:
              send(res, 404, { ok: false, message: `unknown endpoint ${ROUTE_PREFIX}/${method}` })
          }
        } catch (error) {
          send(res, 500, { ok: false, message: error instanceof Error ? error.message : String(error) })
        }
      },
    }),
  ]
  return () => disposers.forEach((dispose) => dispose())
}

/**
 * Cordis plugin entry (dsh-market pattern): acquire webServer, then mount
 * the hot routes. The profile directory comes from the root ctx baseUrl.
 */
export function apply(ctx) {
  console.log('[dsh-web-hot] apply called, baseUrl =', ctx.baseUrl)
  const baseUrl = ctx.baseUrl
  if (baseUrl === undefined) {
    throw new Error('dsh-web-hot: no baseUrl — mount it inside a profile surface (dsh --profile <name>)')
  }
  const profileDir = fileURLToPath(baseUrl)
  ctx.inject(['webServer'], (hostCtx) => {
    console.log('[dsh-web-hot] webServer injected, mounting routes')
    hostCtx.effect(() => {
      console.log('[dsh-web-hot] effect running, registering', ROUTE_PREFIX)
      return mountRoutes(hostCtx, profileDir)
    }, 'dsh-web-hot: http routes')
  })
}

export const name = 'dsh-web-hot'
