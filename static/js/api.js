// api.js — the single HTTP client layer for the UI.
//
// LOAD-BEARING: every request to the backend goes through apiFetch(),
// which attaches BOTH credentials — the enrollment/API key (X-API-Key)
// and, once this device is paired, its per-device bearer token. A past
// UI rewrite bypassed this wrapper and shipped a panel that 401'd on
// every call. If you add new API calls, route them through apiFetch —
// never call fetch() directly.
//
// Two secrets live in localStorage:
//   meow_ac_key           the shared enrollment key (prompted for)
//   meow_ac_device_token  this device's access token (obtained by
//                         completing the pairing flow — see enroll.js)
// apiFetch does not auto-clear either on 401; app.js/enroll.js own that
// decision, because a 401 can mean "wrong key" or "token expired" and
// the recovery differs.

const KEY_STORAGE = "meow_ac_key";
const TOKEN_STORAGE = "meow_ac_device_token";

export function getApiKey(){
  let key = localStorage.getItem(KEY_STORAGE);
  if(!key){
    key = (prompt("API key (from /etc/meow-ac/config.json on meow):") || "").trim();
    if(key) localStorage.setItem(KEY_STORAGE, key);
  }
  return key;
}

export function clearApiKey(){
  localStorage.removeItem(KEY_STORAGE);
}

export function getDeviceToken(){
  return localStorage.getItem(TOKEN_STORAGE) || "";
}

export function setDeviceToken(token){
  localStorage.setItem(TOKEN_STORAGE, token);
}

export function clearDeviceToken(){
  localStorage.removeItem(TOKEN_STORAGE);
}

// Thin fetch wrapper: attaches the API key and (if present) the device
// token. Returns the raw Response — callers inspect status so they can
// tell "needs pairing" (401) from other failures.
export async function apiFetch(path, opts = {}){
  const headers = Object.assign({}, opts.headers, {"X-API-Key": getApiKey()});
  const token = getDeviceToken();
  if(token) headers["Authorization"] = "Bearer " + token;
  return fetch(path, Object.assign({}, opts, {headers}));
}

// Consume a Server-Sent Events endpoint — deliberately over fetch(), NOT
// EventSource.
//
// EventSource cannot send custom request headers. It is the obvious tool for
// SSE and it is unusable here: this UI authenticates with *two* headers
// (X-API-Key and Authorization), so `new EventSource("/api/units/stream")`
// arrives unauthenticated and 401s forever, with no way to attach either
// credential. Some projects work around that by putting a token in the query
// string; that would end up in access logs and in the referrer, which is a poor
// trade for a secret that controls someone's house.
//
// So: fetch() with a streaming body reader, which keeps both headers and keeps
// every request going through this module, per the rule at the top of the file.
//
// Returns the Response so the caller can branch on status the same way it does
// for apiFetch — 401 means re-pair, 404 means an older server with no stream
// route and the caller should fall back to polling. onEvent is called with
// (eventName, dataString) per frame; keepalive comments are skipped.
export async function apiStream(path, { onEvent, onOpen, signal } = {}){
  const res = await apiFetch(path, {
    signal,
    headers: {"Accept": "text/event-stream"},
    cache: "no-store",
  });
  if(!res.ok || !res.body) return res;
  if(onOpen) onOpen();

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  for(;;){
    const { value, done } = await reader.read();
    if(done) break;
    // Normalise CRLF so frame splitting works regardless of what the proxy did.
    buf += decoder.decode(value, {stream: true}).replace(/\r\n/g, "\n");
    let cut;
    // A frame ends at a blank line. Anything still in buf is a partial frame —
    // a chunk boundary can land mid-frame, so it has to be carried over.
    while((cut = buf.indexOf("\n\n")) >= 0){
      const frame = buf.slice(0, cut);
      buf = buf.slice(cut + 2);
      let name = "message";
      const data = [];
      for(const line of frame.split("\n")){
        if(line === "" || line.startsWith(":")) continue;  // keepalive comment
        if(line.startsWith("event:")) name = line.slice(6).trim();
        else if(line.startsWith("data:")) data.push(line.slice(5).replace(/^ /, ""));
      }
      if(data.length && onEvent) onEvent(name, data.join("\n"));
    }
  }
  return res;
}
