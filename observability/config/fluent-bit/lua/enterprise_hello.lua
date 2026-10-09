--[[
Enterprise Hello / portable Datadog package - Fluent Bit Lua filters.

Loaded by every config in observability/config/fluent-bit/ through
  - name: lua
    script: ${FLB_LUA_DIR}/enterprise_hello.lua
    call: <function>

Functions (all are pure record transforms; no I/O, no globals mutated per call):
  eh_redact(tag, ts, record)       -> masks secrets in keys and free-text values
  eh_normalize(tag, ts, record)    -> message/trace-id normalisation (log->message, traceId->trace_id, dd.* flatten)
  eh_k8s(tag, ts, record)          -> service/env/version/ddsource/ddtags from Kubernetes labels (DaemonSet)
  eh_static_tags(tag, ts, record)  -> ddsource/ddtags from FLB_DD_SOURCE / FLB_DD_TAGS env (host + sidecar)
  eh_azure_split(tag, ts, record)  -> explodes an Azure diagnostic-settings batch {"records":[...]} read from
                                       Event Hubs (Kafka input) into one record per log entry (aggregator)

Return codes (Fluent Bit Lua filter contract): -1 drop, 0 unchanged, 1 modified (ts+record), 2 modified record only.
]]

local REDACTED = "[REDACTED]"

-- Words that make a key (or a key=value / key: value pair inside free text) sensitive.
local SENSITIVE_WORDS = {
  "password", "passwd", "pwd", "secret", "token", "apikey", "api_key", "api-key",
  "accountkey", "sharedaccesskey", "sharedaccesssignature", "connectionstring",
  "connection_string", "authorization", "client_secret", "key",
}

-- Keys that must never be redacted even though they contain a sensitive word.
local SAFE_KEYS = {
  ["idempotency_key"] = true, ["idempotency-key"] = true, ["partition_key"] = true,
}

local function ci_pattern(word)
  -- Build a case-insensitive Lua pattern for a literal word (letters only are case folded).
  return (word:gsub("%a", function(c)
    return "[" .. c:lower() .. c:upper() .. "]"
  end):gsub("%-", "%%-"))
end

local VALUE_PATTERNS = {}
for _, w in ipairs(SENSITIVE_WORDS) do
  -- key=value, key: value, "key":"value", key = 'value'
  table.insert(VALUE_PATTERNS, "(" .. ci_pattern(w) .. "[\"']?%s*[=:]%s*[\"']?)[^%s,;&\"'}]+")
end
local BEARER_PATTERN = "([Bb][Ee][Aa][Rr][Ee][Rr]%s+)[%w%-%._~%+/]+=*"
local SIG_PATTERN = "([%?&][Ss][Ii][Gg]=)[^&%s\"']+"

local function redact_string(s)
  -- bearer tokens first: "Authorization: Bearer <jwt>" must lose the token, not just the word "Bearer"
  local out = s:gsub(BEARER_PATTERN, "%1" .. REDACTED)
  out = out:gsub(SIG_PATTERN, "%1" .. REDACTED)
  for _, p in ipairs(VALUE_PATTERNS) do
    out = out:gsub(p, "%1" .. REDACTED)
  end
  return out
end

local function key_is_sensitive(k)
  if type(k) ~= "string" then
    return false
  end
  local lk = k:lower()
  if SAFE_KEYS[lk] then
    return false
  end
  -- trace/span identifiers and Datadog reserved attributes are never secrets
  if lk:find("trace_id", 1, true) or lk:find("span_id", 1, true) or lk:sub(1, 3) == "dd." then
    return false
  end
  for _, w in ipairs(SENSITIVE_WORDS) do
    if w ~= "key" and lk:find(w, 1, true) then
      return true
    end
  end
  return lk == "key" or lk:sub(-4) == "_key" or lk:sub(-4) == "-key" or lk:sub(-4) == ".key"
end

local function redact_value(v, depth)
  local t = type(v)
  if t == "string" then
    return redact_string(v)
  elseif t == "table" and depth < 6 then
    for k, inner in pairs(v) do
      if key_is_sensitive(k) and (type(inner) == "string" or type(inner) == "number") then
        v[k] = REDACTED
      else
        v[k] = redact_value(inner, depth + 1)
      end
    end
  end
  return v
end

function eh_redact(tag, ts, record)
  redact_value(record, 0)
  return 2, ts, record
end

-- ---------------------------------------------------------------------------------------------
local TRACE_ALIASES = { "traceId", "TraceId", "trace.id", "otel.trace_id", "traceid" }
local SPAN_ALIASES = { "spanId", "SpanId", "span.id", "otel.span_id", "spanid" }

function eh_normalize(tag, ts, record)
  -- unparsed lines (stack traces, plain text) arrive as "log": expose them as "message"
  if record["message"] == nil and record["log"] ~= nil then
    record["message"] = record["log"]
    record["log"] = nil
  end
  if record["trace_id"] == nil then
    for _, k in ipairs(TRACE_ALIASES) do
      if record[k] ~= nil then
        record["trace_id"] = record[k]
        record[k] = nil
        break
      end
    end
  end
  if record["span_id"] == nil then
    for _, k in ipairs(SPAN_ALIASES) do
      if record[k] ~= nil then
        record["span_id"] = record[k]
        record[k] = nil
        break
      end
    end
  end
  -- nested {"dd": {"trace_id": ..}} (some log enrichers) -> flat "dd.trace_id" (Datadog reserved attribute)
  local dd = record["dd"]
  if type(dd) == "table" then
    for k, v in pairs(dd) do
      if record["dd." .. k] == nil then
        record["dd." .. k] = v
      end
    end
    record["dd"] = nil
  end
  -- Datadog status remapper reads "status"/"level"; keep "level" lower-case and stable
  if type(record["level"]) == "string" then
    record["level"] = record["level"]:lower()
  end
  return 2, ts, record
end

-- ---------------------------------------------------------------------------------------------
local function append_tag(tags, k, v)
  if v ~= nil and v ~= "" then
    table.insert(tags, k .. ":" .. tostring(v))
  end
end

local function env_or(name, default)
  local v = os.getenv(name)
  if v == nil or v == "" then
    return default
  end
  return v
end

local STATIC_TAGS = env_or("FLB_DD_TAGS", "")

function eh_static_tags(tag, ts, record)
  if record["ddsource"] == nil then
    record["ddsource"] = env_or("FLB_DD_SOURCE", "enterprise-hello")
  end
  if record["service"] == nil then
    local s = env_or("FLB_DD_SERVICE", nil)
    if s ~= nil then
      record["service"] = s
    end
  end
  local tags = {}
  if STATIC_TAGS ~= "" then
    table.insert(tags, STATIC_TAGS)
  end
  if record["ddtags"] ~= nil and record["ddtags"] ~= "" then
    table.insert(tags, record["ddtags"])
  end
  if #tags > 0 then
    record["ddtags"] = table.concat(tags, ",")
  end
  return 2, ts, record
end

local K8S_LABEL_TAGS = {
  { "tags.datadoghq.com/env", "env" },
  { "tags.datadoghq.com/version", "version" },
  { "team", "team" },
  { "domain", "domain" },
  { "tier", "tier" },
  { "application", "application" },
  { "app.kubernetes.io/part-of", "application" },
}

function eh_k8s(tag, ts, record)
  local k8s = record["kubernetes"]
  if type(k8s) ~= "table" then
    return eh_static_tags(tag, ts, record)
  end
  local labels = k8s["labels"] or {}
  if record["service"] == nil then
    record["service"] = labels["tags.datadoghq.com/service"] or labels["app.kubernetes.io/name"] or labels["app"] or k8s["container_name"]
  end
  if record["env"] == nil and labels["tags.datadoghq.com/env"] ~= nil then
    record["env"] = labels["tags.datadoghq.com/env"]
  end
  if record["version"] == nil and labels["tags.datadoghq.com/version"] ~= nil then
    record["version"] = labels["tags.datadoghq.com/version"]
  end
  if record["ddsource"] == nil then
    record["ddsource"] = labels["logs.datadoghq.com/source"] or env_or("FLB_DD_SOURCE", "kubernetes")
  end
  local tags = {}
  append_tag(tags, "kube_namespace", k8s["namespace_name"])
  append_tag(tags, "pod_name", k8s["pod_name"])
  append_tag(tags, "kube_container_name", k8s["container_name"])
  append_tag(tags, "kube_node", k8s["host"])
  local seen = {}
  for _, m in ipairs(K8S_LABEL_TAGS) do
    local v = labels[m[1]]
    if v ~= nil and not seen[m[2]] then
      append_tag(tags, m[2], v)
      seen[m[2]] = true
    end
  end
  if STATIC_TAGS ~= "" then
    table.insert(tags, STATIC_TAGS)
  end
  record["ddtags"] = table.concat(tags, ",")
  -- drop bulky metadata Datadog does not need (labels already mapped to tags)
  k8s["annotations"] = nil
  k8s["docker_id"] = nil
  k8s["container_hash"] = nil
  return 2, ts, record
end

-- ---------------------------------------------------------------------------------------------
-- Azure diagnostic settings -> Event Hubs batches: {"records":[{time, resourceId, category, properties...}]}
local APP_MESSAGE_FIELDS = { "ResultDescription", "resultDescription", "message", "Message", "Log", "log", "msg" }

local function provider_of(resource_id)
  if type(resource_id) ~= "string" then
    return nil, nil, nil, nil
  end
  local rid = resource_id:lower()
  local sub = rid:match("/subscriptions/([^/]+)")
  local rg = rid:match("/resourcegroups/([^/]+)")
  local prov = rid:match("/providers/microsoft%.([^/]+)")
  local name = rid:match("/([^/]+)$")
  return sub, rg, prov, name
end

local function azure_entry(entry, topic)
  local out = {}
  for k, v in pairs(entry) do
    out[k] = v
  end
  local rid = entry["resourceId"] or entry["ResourceId"] or entry["resource_id"]
  local sub, rg, prov, name = provider_of(rid)
  local props = entry["properties"]
  local msg = nil
  if type(props) == "table" then
    for _, f in ipairs(APP_MESSAGE_FIELDS) do
      if type(props[f]) == "string" and props[f] ~= "" then
        msg = props[f]
        break
      end
    end
  end
  if msg == nil then
    for _, f in ipairs(APP_MESSAGE_FIELDS) do
      if type(entry[f]) == "string" and entry[f] ~= "" then
        msg = entry[f]
        break
      end
    end
  end
  if msg ~= nil then
    -- trailing newlines from console streams
    out["message"] = msg:gsub("[\r\n]+$", "")
  end
  if prov ~= nil then
    out["ddsource"] = "azure." .. prov
  else
    out["ddsource"] = "azure"
  end
  local is_json = type(out["message"]) == "string" and out["message"]:sub(1, 1) == "{"
  if not is_json and out["service"] == nil and name ~= nil then
    out["service"] = name
  end
  local tags = {}
  append_tag(tags, "resource_id", rid and rid:lower() or nil)
  append_tag(tags, "subscription_id", sub)
  append_tag(tags, "resource_group", rg)
  append_tag(tags, "category", entry["category"] or entry["Category"])
  append_tag(tags, "eventhub", topic)
  append_tag(tags, "forwarder", "fluent-bit-aggregator")
  if STATIC_TAGS ~= "" then
    table.insert(tags, STATIC_TAGS)
  end
  out["ddtags"] = table.concat(tags, ",")
  return out
end

-- ACA environments export ContainerAppConsoleLogs for EVERY app in the environment, but apps with a
-- Fluent Bit sidecar are already collected -> keep only allow-listed container apps/jobs (typically
-- jobs, which have no sidecar). FLB_ACA_CONSOLE_ALLOW: comma list of exact names or prefixes ending in
-- '*' (e.g. "eh-caj-*"); empty = keep all. Fluent Bit sidecar containers' own console output is dropped.
local ACA_ALLOW = {}
for item in string.gmatch(env_or("FLB_ACA_CONSOLE_ALLOW", ""), "[^,%s]+") do
  table.insert(ACA_ALLOW, item)
end

local function aca_console_allowed(entry)
  local cat = entry["category"] or entry["Category"]
  if cat ~= "ContainerAppConsoleLogs" and cat ~= "ContainerAppConsoleLogs_CL" then
    return true
  end
  local p = entry["properties"]
  if type(p) ~= "table" then
    return #ACA_ALLOW == 0
  end
  local container = p["ContainerName"] or p["ContainerName_s"]
  if container == "fluent-bit" then
    return false
  end
  if #ACA_ALLOW == 0 then
    return true
  end
  local name = p["ContainerAppName"] or p["ContainerAppName_s"] or p["JobName"] or ""
  for _, a in ipairs(ACA_ALLOW) do
    if a:sub(-1) == "*" then
      if name:sub(1, #a - 1) == a:sub(1, -2) then
        return true
      end
    elseif name == a then
      return true
    end
  end
  return false
end

function eh_azure_split(tag, ts, record)
  -- kafka input (format json) wraps the message: {topic, partition, offset, key, payload}
  local payload = record["payload"]
  local topic = record["topic"]
  if payload == nil then
    payload = record
  end
  if type(payload) ~= "table" then
    -- not JSON: forward as plain message
    return 1, ts, { message = tostring(payload), ddsource = "azure", ddtags = "eventhub:" .. tostring(topic) }
  end
  local entries = payload["records"]
  if type(entries) ~= "table" then
    if not aca_console_allowed(payload) then
      return -1, ts, record
    end
    return 1, ts, azure_entry(payload, topic)
  end
  local out = {}
  for _, e in ipairs(entries) do
    if type(e) == "table" and aca_console_allowed(e) then
      table.insert(out, azure_entry(e, topic))
    end
  end
  if #out == 0 then
    return -1, ts, record
  end
  return 1, ts, out
end

-- ---------------------------------------------------------------------------------------------
-- Last filter of every config: mark the collection path (monitors/verifiers filter on it) and make
-- sure the canary carries env. Idempotent (records forwarded sidecar -> aggregator are not re-tagged).
local PIPELINE_TAG = "telemetry.pipeline:fluent-bit"

function eh_finalize(tag, ts, record)
  local t = record["ddtags"]
  if t == nil or t == "" then
    t = STATIC_TAGS
  end
  if t == nil or t == "" then
    t = PIPELINE_TAG
  elseif not string.find("," .. t .. ",", "," .. PIPELINE_TAG .. ",", 1, true) then
    t = t .. "," .. PIPELINE_TAG
  end
  if record["canary"] == true or record["canary"] == "true" then
    if not string.find("," .. t .. ",", ",env:", 1, true) and os.getenv("FLB_DD_TAGS") == nil then
      t = t .. ",env:unknown"
    end
  end
  record["ddtags"] = t
  return 2, ts, record
end
