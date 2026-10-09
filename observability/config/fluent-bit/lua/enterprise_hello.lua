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
                                       Event Hubs (Kafka input) into one record per log entry (aggregator) and
                                       shapes it like Datadog's own Azure forwarder (ddsource azure.<provider>,
                                       service azure, subscription_id/resource_group/tenant tags), with a
                                       redelivery dedup cache and a Datadog 1 MB size guard

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
  -- Azure identity claims that are metadata, not secrets (Activity Log identity.claims)
  ["pwd_exp"] = true, ["pwd_url"] = true,
}

-- Azure/Entra/Kubernetes metadata keys that contain a sensitive word but carry no secret: token TYPE / NAME /
-- STATUS / identifier fields of Entra sign-in logs (tokenIssuerType, incomingTokenType, uniqueTokenIdentifier,
-- signInTokenProtectionStatus, ...) and Kubernetes audit annotations (authorization.k8s.io/decision|reason).
-- Datadog's Entra ID pipeline and Cloud SIEM rules read these fields, so they must arrive intact.
local SAFE_SUFFIXES = { "type", "name", "status", "statusdetails", "details", "identifier", "source", "issuer", "hash" }
local function azure_metadata_key(lk)
  if lk:find("authorization.k8s.io/", 1, true) then
    return true
  end
  if lk:find("token", 1, true) then
    for _, suf in ipairs(SAFE_SUFFIXES) do
      if lk:sub(-#suf) == suf then
        return true
      end
    end
  end
  return false
end

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
  if SAFE_KEYS[lk] or azure_metadata_key(lk) then
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
  elseif t == "table" and depth < 8 then
    -- {"key": "<name>", "value": "<v>"} pairs (Entra authenticationProcessingDetails, additionalDetails, ...):
    -- "key" is a label, not a secret; redact the value only when the label names a secret.
    local kv_pair = type(v["key"]) == "string" and v["value"] ~= nil
    for k, inner in pairs(v) do
      if kv_pair and k == "key" then
        -- keep the label
      elseif kv_pair and k == "value" and key_is_sensitive(v["key"]) and (type(inner) == "string" or type(inner) == "number") then
        v[k] = REDACTED
      elseif key_is_sensitive(k) and (type(inner) == "string" or type(inner) == "number") then
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
  -- Datadog status remapper reads "status"/"level"; keep "level" lower-case and stable. Azure resource-log
  -- records (resourceId present) keep their original "level" (Datadog's Azure pipelines read it verbatim).
  if type(record["level"]) == "string" and record["resourceId"] == nil and record["ResourceId"] == nil then
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
--
-- Record shape sent to Datadog (matches Datadog's own Azure log forwarder, so the out-of-the-box Azure log
-- pipelines, facets and Cloud SIEM rules apply - see docs/guides/azure-logs-to-datadog.md):
--   * every Azure field is kept verbatim at the top level (time, resourceId, operationName, category, resultType,
--     resultSignature, callerIpAddress, correlationId, identity, level, location, properties ...) - no flattening
--   * ddsource  azure.<provider namespace> from resourceId (microsoft.keyvault -> azure.keyvault), subscription-only
--               ids -> azure.subscription, resource-group ids -> azure.resourcegroup, /tenants/<id>/providers/
--               microsoft.aadiam -> azure.activedirectory, no resourceId -> azure
--   * service    "azure" (FLB_AZURE_SERVICE) for platform categories; application categories keep the app's own
--                service (JSON line) or the resource name
--   * ddsourcecategory azure; ddtags subscription_id, resource_group, tenant (Datadog forwarder names) plus
--     resource_type, resource_name, resource_id, region, category, azure_log_type, env, eventhub, forwarder
-- Additive only: aks_audit.* (verb, objectRef, user, response code) lifted from the kube-audit JSON string in
-- properties.log so exclusion filters / monitors can use them; properties.log itself is untouched.
local APP_MESSAGE_FIELDS = { "ResultDescription", "resultDescription", "message", "Message", "Log", "log", "msg" }

-- application-log categories (app-logs hub); everything else is a platform / control-plane category
local APP_CATEGORIES = {
  AppServiceConsoleLogs = true, AppServiceAppLogs = true, FunctionAppLogs = true, WorkflowRuntime = true,
  ContainerAppConsoleLogs = true, ContainerAppConsoleLogs_CL = true,
}
local ACTIVITY_CATEGORIES = {
  Administrative = true, Security = true, ServiceHealth = true, Alert = true, Recommendation = true,
  Policy = true, Autoscale = true, ResourceHealth = true,
}
local AKS_AUDIT_CATEGORIES = { ["kube-audit"] = true, ["kube-audit-admin"] = true }

local AZURE_SERVICE = env_or("FLB_AZURE_SERVICE", "azure")
local APP_TOPIC = env_or("FLB_EVENTHUB_APP_TOPIC", "app-logs")
-- Datadog accepts at most 1 MB per log (larger logs are truncated by the intake without telling you which field):
-- keep a margin for JSON escaping and tags. FLB_AZURE_MAX_RECORD_BYTES overrides (tests use a small value).
local MAX_RECORD_BYTES = tonumber(env_or("FLB_AZURE_MAX_RECORD_BYTES", "900000")) or 900000
local DEDUP_SIZE = tonumber(env_or("FLB_AZURE_DEDUP_CACHE", "20000")) or 20000

-- FLB_AZURE_ENV_BY_SUBSCRIPTION="<subscription-guid>=<env>,..." maps subscriptions to an env tag when the record
-- itself carries no env (diagnostic records do not include resource tags).
local ENV_BY_SUB = {}
for pair in string.gmatch(env_or("FLB_AZURE_ENV_BY_SUBSCRIPTION", ""), "[^,%s]+") do
  local sub, env = pair:match("^([^=]+)=(.+)$")
  if sub ~= nil then
    ENV_BY_SUB[sub:lower()] = env
  end
end

local function source_type(seg)
  if seg == nil then
    return nil
  end
  local s = seg:gsub("^microsoft%.", "azure.", 1)
  return s
end

-- Port of extractMetadataFromStandardLog() of Datadog's Azure forwarder (datadog-serverless-functions,
-- azure/activity_logs_monitoring/index.js): source from the provider namespace, subscription_id /
-- resource_group / tenant tags.
local function azure_metadata(resource_id)
  local m = { source = nil, sub = nil, rg = nil, tenant = nil, rtype = nil, rname = nil }
  if type(resource_id) ~= "string" or resource_id == "" then
    return m
  end
  local parts = {}
  for seg in resource_id:lower():gmatch("[^/]+") do
    table.insert(parts, seg)
  end
  if parts[1] == "subscriptions" then
    m.sub = parts[2]
    if #parts == 2 then
      m.source = "azure.subscription"
      return m
    end
    if #parts > 3 then
      if parts[3] == "providers" and parts[4]:sub(1, 10) == "microsoft." then
        m.source = source_type(parts[4])
      else
        m.rg = parts[4]
        if #parts == 4 then
          m.source = "azure.resourcegroup"
          return m
        end
      end
    end
    if #parts > 5 and parts[6]:sub(1, 10) == "microsoft." then
      m.source = source_type(parts[6])
    end
  elseif parts[1] == "tenants" then
    if #parts > 3 then
      m.tenant = parts[2]
    end
    if parts[4] ~= nil then
      m.source = source_type(parts[4]):gsub("aadiam", "activedirectory")
    end
  end
  -- resource type / name: provider namespace + every type segment after it (microsoft.web/sites/slots)
  local pidx = nil
  for i, seg in ipairs(parts) do
    if seg == "providers" then
      pidx = i
    end
  end
  if pidx ~= nil and parts[pidx + 1] ~= nil then
    local t = { parts[pidx + 1] }
    local i = pidx + 2
    while parts[i] ~= nil do
      table.insert(t, parts[i])
      i = i + 2
    end
    if #t > 1 then
      m.rtype = table.concat(t, "/")
      m.rname = parts[#parts]
    end
  end
  return m
end

-- approximate JSON size of a value (bytes); good enough for the 1 MB guard
local function approx_size(v, depth)
  local t = type(v)
  if t == "string" then
    return #v + 2
  elseif t == "table" then
    if depth > 20 then
      return 0
    end
    local n = 2
    for k, inner in pairs(v) do
      n = n + (type(k) == "string" and #k + 3 or 1) + approx_size(inner, depth + 1) + 1
    end
    return n
  elseif t == "number" then
    return 24
  end
  return 5
end

local function largest_string(v, path, depth, best)
  for k, inner in pairs(v) do
    local p = path == "" and tostring(k) or (path .. "." .. tostring(k))
    if type(inner) == "string" then
      if best.len < #inner then
        best.len, best.parent, best.key, best.path = #inner, v, k, p
      end
    elseif type(inner) == "table" and depth < 20 then
      largest_string(inner, p, depth + 1, best)
    end
  end
  return best
end

local TRUNC_MARK = "...[TRUNCATED by fluent-bit: Datadog 1MB log limit]"

-- Shrink the largest string fields until the record fits; flag what was cut (never drop the record).
local function size_guard(rec)
  local size = approx_size(rec, 0)
  if size <= MAX_RECORD_BYTES then
    return false
  end
  local cut = {}
  for _ = 1, 16 do
    local best = largest_string(rec, "", 0, { len = 0 })
    if best.parent == nil or best.len <= 1024 then
      break
    end
    local over = size - MAX_RECORD_BYTES
    local keep = math.max(1024, best.len - over - #TRUNC_MARK - 64)
    best.parent[best.key] = best.parent[best.key]:sub(1, keep) .. TRUNC_MARK
    table.insert(cut, best.path)
    size = approx_size(rec, 0)
    if size <= MAX_RECORD_BYTES then
      break
    end
  end
  rec["truncated"] = true
  rec["truncated_fields"] = cut
  return true
end

-- Event Hubs is at-least-once: a consumer-group rebalance or restart re-reads the last uncommitted batch. Records
-- that carry a strong identity are remembered in a bounded FIFO cache and delivered once.
local seen, ring, ring_pos = {}, {}, 0

local function dedup_key(e, cat)
  local p = e["properties"]
  if type(p) == "table" and type(p["id"]) == "string" and (cat == "SignInLogs" or cat == "AuditLogs" or cat:find("SignInLogs", 1, true)) then
    return cat .. "|" .. p["id"]
  end
  local corr = e["correlationId"]
  if type(corr) == "string" and corr ~= "" then
    return table.concat({ tostring(e["time"]), tostring(e["resourceId"] or e["ResourceId"]), cat,
      tostring(e["operationName"]), tostring(e["resultType"]), corr, tostring(type(p) == "table" and p["eventDataId"] or "") }, "|")
  end
  return nil
end

local function already_seen(key)
  if key == nil or DEDUP_SIZE <= 0 then
    return false
  end
  if seen[key] then
    return true
  end
  ring_pos = ring_pos % DEDUP_SIZE + 1
  local old = ring[ring_pos]
  if old ~= nil then
    seen[old] = nil
  end
  ring[ring_pos] = key
  seen[key] = true
  return false
end

-- kube-audit / kube-audit-admin: properties.log is the Kubernetes audit event as a JSON STRING. Lift a few
-- bounded fields (additive, outside properties) for exclusion filters and monitors.
local function aks_audit_fields(log)
  if type(log) ~= "string" or log:sub(1, 1) ~= "{" then
    return nil
  end
  local a = {}
  a["verb"] = log:match('"verb"%s*:%s*"([^"]*)"')
  local obj = log:match('"objectRef"%s*:%s*(%b{})')
  if obj ~= nil then
    a["objectRef"] = {
      resource = obj:match('"resource"%s*:%s*"([^"]*)"'),
      subresource = obj:match('"subresource"%s*:%s*"([^"]*)"'),
      namespace = obj:match('"namespace"%s*:%s*"([^"]*)"'),
      name = obj:match('"name"%s*:%s*"([^"]*)"'),
    }
  end
  local user = log:match('"user"%s*:%s*(%b{})')
  if user ~= nil then
    a["user"] = { username = user:match('"username"%s*:%s*"([^"]*)"') }
  end
  local rs = log:match('"responseStatus"%s*:%s*(%b{})')
  if rs ~= nil then
    a["responseStatus"] = { code = tonumber(rs:match('"code"%s*:%s*(%d+)')) }
  end
  a["auditID"] = log:match('"auditID"%s*:%s*"([^"]*)"')
  return a
end

local function env_of(e, sub)
  local tags = e["tags"]
  if type(tags) == "table" then
    local v = tags["env"] or tags["environment"] or tags["Environment"]
    if type(v) == "string" and v ~= "" then
      return v
    end
  end
  if sub ~= nil and ENV_BY_SUB[sub] ~= nil then
    return ENV_BY_SUB[sub]
  end
  return nil
end

local function static_tags_without_env()
  local out = {}
  for t in string.gmatch(STATIC_TAGS, "[^,]+") do
    if t:sub(1, 4) ~= "env:" then
      table.insert(out, t)
    end
  end
  return table.concat(out, ",")
end

local function azure_entry(entry, topic)
  local out = {}
  for k, v in pairs(entry) do
    out[k] = v
  end
  local rid = entry["resourceId"] or entry["ResourceId"] or entry["resource_id"]
  local md = azure_metadata(rid)
  local cat = entry["category"] or entry["Category"]
  local is_app = cat ~= nil and APP_CATEGORIES[cat] == true
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
    msg = msg:gsub("[\r\n]+$", "")
    -- platform records: never synthesize a JSON message (the parser would lift e.g. a kube-audit event to the
    -- top level and break Datadog's Azure pipelines); the structured fields stay where Azure put them
    if is_app or msg:sub(1, 1) ~= "{" then
      out["message"] = msg
    end
  end

  out["ddsource"] = md.source or "azure"
  out["ddsourcecategory"] = "azure"
  local is_json = type(out["message"]) == "string" and out["message"]:sub(1, 1) == "{"
  if is_app then
    if not is_json and out["service"] == nil and md.rname ~= nil then
      out["service"] = md.rname
    end
  elseif out["service"] == nil then
    out["service"] = AZURE_SERVICE
  end

  local log_type = "resource"
  if is_app then
    log_type = "application"
  elseif md.tenant ~= nil or (out["ddsource"] == "azure.activedirectory") then
    log_type = "entra"
  elseif cat ~= nil and ACTIVITY_CATEGORIES[cat] then
    log_type = "activity"
  end

  if cat ~= nil and AKS_AUDIT_CATEGORIES[cat] and type(props) == "table" then
    out["aks_audit"] = aks_audit_fields(props["log"])
  end

  local tags = {}
  append_tag(tags, "subscription_id", md.sub)
  append_tag(tags, "resource_group", md.rg)
  append_tag(tags, "tenant", md.tenant)
  append_tag(tags, "resource_type", md.rtype)
  append_tag(tags, "resource_name", md.rname)
  append_tag(tags, "resource_id", rid and rid:lower() or nil)
  local loc = entry["location"] or entry["Location"]
  if log_type ~= "activity" and type(loc) == "string" and loc ~= "" and loc:lower() ~= "global" then
    append_tag(tags, "region", (loc:lower():gsub("%s+", "")))
  end
  append_tag(tags, "category", cat)
  append_tag(tags, "azure_log_type", log_type)
  local env = env_of(entry, md.sub)
  append_tag(tags, "env", env)
  append_tag(tags, "eventhub", topic)
  append_tag(tags, "forwarder", "fluent-bit-aggregator")
  local static = env ~= nil and static_tags_without_env() or STATIC_TAGS
  if static ~= "" then
    table.insert(tags, static)
  end
  if size_guard(out) then
    table.insert(tags, "truncated:true")
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

-- Duplicate prevention at the consumer: application categories are only ever valid on the app-logs hub. A
-- hand-made (portal) diagnostic setting that also sends them to platform-logs / activity-logs would otherwise
-- duplicate every application log line.
local function wanted(entry, topic)
  if not aca_console_allowed(entry) then
    return false
  end
  local cat = entry["category"] or entry["Category"]
  if topic ~= nil and topic ~= APP_TOPIC and cat ~= nil and APP_CATEGORIES[cat] then
    return false
  end
  if already_seen(dedup_key(entry, tostring(cat))) then
    return false
  end
  return true
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
    if not wanted(payload, topic) then
      return -1, ts, record
    end
    return 1, ts, azure_entry(payload, topic)
  end
  local out = {}
  for _, e in ipairs(entries) do
    if type(e) == "table" and wanted(e, topic) then
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
