// Reads the signed-in user's mail inside this page only.
// Fetch stays on outlook.office.com / outlook.office365.com.
// Does not read or return access tokens, refresh tokens, or client credentials.
(function () {
  if (globalThis.__owaBridge && globalThis.__owaBridge.__installed) {
    return;
  }

  var ADAPTER_VERSION = "1.0.0";
  var cache = new Map();
  var lastProvider = null;
  var lastExtract = null;
  var lastLoggedIn = false;

  function redact(input) {
    var text = String(input == null ? "" : input);
    text = text.replace(/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g, "[redacted]");
    text = text.replace(/(access_token|refresh_token|id_token|client_secret|X-OWA-CANARY|FedAuth|Bearer)\s*["':= ]+\s*[^"'&\s<]+/gi, "$1=[redacted]");
    return text;
  }

  function nowMs() {
    if (globalThis.performance && typeof performance.now === "function") return performance.now();
    return Date.now();
  }

  function freshTrace(params) {
    return {
      attempted: [],
      anchors: [],
      warnings: [],
      provider: null,
      durationMs: 0,
      correlationId: params && params.correlationId ? String(params.correlationId) : null
    };
  }

  function finish(status, body, trace, started, target, ok, includeDebug) {
    var durationMs = Math.max(0, Math.round(nowMs() - started));
    trace.durationMs = durationMs;
    if (trace.provider) lastProvider = trace.provider;
    lastExtract = {
      at: new Date().toISOString(),
      durationMs: durationMs,
      ok: !!ok,
      target: target
    };
    if (status === 200 && (target === "me" || target === "messages" || target === "message")) lastLoggedIn = true;
    if (status === 401) lastLoggedIn = false;
    if (includeDebug) {
      body._debug = {
        provider: trace.provider,
        durationMs: durationMs,
        attempted: trace.attempted,
        anchors: trace.anchors,
        warnings: trace.warnings,
        correlationId: trace.correlationId,
        adapterVersion: ADAPTER_VERSION
      };
    }
    return {
      status: status,
      body: body,
      trace: {
        provider: trace.provider,
        durationMs: durationMs,
        attempted: trace.attempted,
        anchors: trace.anchors,
        warnings: trace.warnings
      }
    };
  }

  function toISO(value) {
    if (value == null || value === "") return null;
    if (typeof value === "number") {
      var numeric = new Date(value);
      return isNaN(numeric.getTime()) ? null : numeric.toISOString();
    }
    var text = String(value);
    var wrapped = /\/Date\((-?\d+)\)\//.exec(text);
    if (wrapped) {
      var fromMillis = new Date(Number(wrapped[1]));
      return isNaN(fromMillis.getTime()) ? null : fromMillis.toISOString();
    }
    var parsed = new Date(text);
    if (!isNaN(parsed.getTime())) return parsed.toISOString();
    return text;
  }

  function person(input) {
    if (!input || typeof input !== "object") return { name: "", address: "" };
    if (input.EmailAddress && typeof input.EmailAddress === "object") {
      return {
        name: input.EmailAddress.Name || input.EmailAddress.name || "",
        address: input.EmailAddress.Address || input.EmailAddress.address || ""
      };
    }
    if (input.Mailbox) return person(input.Mailbox);
    var address = input.EmailAddress || input.Address || input.address || input.email || "";
    if (address && typeof address !== "string") address = "";
    return {
      name: input.Name || input.name || "",
      address: address
    };
  }

  function people(list) {
    if (!list) return [];
    var items = Array.isArray(list) ? list : [list];
    var out = [];
    for (var i = 0; i < items.length; i++) {
      var entry = person(items[i]);
      if (entry.name || entry.address) out.push(entry);
    }
    return out;
  }

  function importanceOf(value) {
    var text = String(value || "normal").toLowerCase();
    if (text === "high") return "high";
    if (text === "low") return "low";
    return "normal";
  }

  function schemaMessage(partial) {
    return {
      id: partial.id || "",
      conversationId: partial.conversationId || "",
      subject: partial.subject || "",
      from: partial.from || { name: "", address: "" },
      to: partial.to || [],
      receivedDateTime: partial.receivedDateTime || null,
      bodyPreview: partial.bodyPreview || "",
      isRead: !!partial.isRead,
      hasAttachments: !!partial.hasAttachments,
      importance: importanceOf(partial.importance)
    };
  }

  function conversationIdOf(value) {
    if (!value) return "";
    if (typeof value === "string") return value;
    return value.Id || value.id || "";
  }

  function adaptRestMessage(raw) {
    raw = raw || {};
    return schemaMessage({
      id: raw.Id || raw.id || "",
      conversationId: conversationIdOf(raw.ConversationId || raw.conversationId),
      subject: raw.Subject || raw.subject || "",
      from: person(raw.From || raw.Sender),
      to: people(raw.ToRecipients),
      receivedDateTime: toISO(raw.ReceivedDateTime || raw.receivedDateTime),
      bodyPreview: raw.BodyPreview || raw.Preview || "",
      isRead: raw.IsRead != null ? !!raw.IsRead : !!raw.isRead,
      hasAttachments: !!(raw.HasAttachments || raw.hasAttachments),
      importance: raw.Importance || raw.importance
    });
  }

  function bodyOf(raw) {
    var body = raw.Body || raw.TextBody || {};
    if (typeof body === "string") return { contentType: "text", content: body };
    var content = body.Content || body.Value || "";
    var kind = String(body.ContentType || body.BodyType || "text").toLowerCase();
    return { contentType: kind.indexOf("html") >= 0 ? "html" : "text", content: content };
  }

  function attachmentsOf(raw) {
    var list = raw.Attachments || raw.attachments || [];
    if (!Array.isArray(list)) return [];
    var out = [];
    for (var i = 0; i < list.length; i++) {
      var item = list[i] || {};
      if (item["@odata.type"] && String(item["@odata.type"]).indexOf("ItemAttachment") >= 0 && !item.Name && !item.name) {
        continue;
      }
      out.push({
        name: item.Name || item.name || "",
        size: Number(item.Size || item.size || 0),
        contentType: item.ContentType || item.contentType || "application/octet-stream"
      });
    }
    return out;
  }

  function adaptRestDetail(raw) {
    var message = adaptRestMessage(raw);
    message.cc = people(raw.CcRecipients);
    message.body = bodyOf(raw);
    message.attachments = attachmentsOf(raw);
    return message;
  }

  function adaptEwsMessage(raw) {
    raw = raw || {};
    var idObject = raw.ItemId || {};
    var id = typeof raw.Id === "string" ? raw.Id : (idObject.Id || "");
    var to = people(raw.ToRecipients);
    if (!to.length && raw.DisplayTo) {
      to = String(raw.DisplayTo).split(";").map(function (part) {
        return { name: part.trim(), address: "" };
      }).filter(function (entry) { return entry.name; });
    }
    return schemaMessage({
      id: id,
      conversationId: conversationIdOf(raw.ConversationId),
      subject: raw.Subject || "",
      from: person(raw.From || raw.Sender),
      to: to,
      receivedDateTime: toISO(raw.DateTimeReceived || raw.ReceivedDateTime),
      bodyPreview: raw.Preview || raw.BodyPreview || "",
      isRead: raw.IsRead != null ? !!raw.IsRead : false,
      hasAttachments: !!raw.HasAttachments,
      importance: raw.Importance
    });
  }

  function adaptEwsDetail(raw) {
    var message = adaptEwsMessage(raw);
    message.cc = people(raw.CcRecipients);
    if (!message.cc.length && raw.DisplayCc) {
      message.cc = String(raw.DisplayCc).split(";").map(function (part) {
        return { name: part.trim(), address: "" };
      }).filter(function (entry) { return entry.name; });
    }
    message.body = bodyOf(raw);
    message.attachments = attachmentsOf(raw);
    return message;
  }

  function adaptDomItem(raw) {
    return schemaMessage({
      id: raw.id,
      conversationId: "",
      subject: raw.subject || "",
      from: { name: raw.fromName || "", address: raw.fromAddress || "" },
      to: [],
      receivedDateTime: raw.receivedDateTime || null,
      bodyPreview: raw.bodyPreview || "",
      isRead: !raw.unread,
      hasAttachments: !!raw.hasAttachments,
      importance: "normal"
    });
  }

  function tenantFromAddress(address) {
    if (!address || address.indexOf("@") < 0) return null;
    var domain = address.split("@")[1];
    if (domain && domain.toLowerCase().indexOf(".onmicrosoft.com") === domain.length - ".onmicrosoft.com".length) {
      return domain;
    }
    return null;
  }

  function adaptRestUser(raw) {
    raw = raw || {};
    var address = raw.Mail || raw.EmailAddress || raw.UserPrincipalName || raw.mail || raw.userPrincipalName || "";
    if (address && typeof address !== "string") address = "";
    var displayName = raw.DisplayName || raw.displayName || "";
    var tenant = raw.TenantDomain || raw.tenant || tenantFromAddress(address);
    return {
      displayName: displayName,
      address: address,
      tenant: tenant,
      loggedIn: true
    };
  }

  function mapFolder(name) {
    var raw = String(name || "inbox").trim() || "inbox";
    var key = raw.toLowerCase();
    var table = {
      inbox: { rest: "inbox", ews: "inbox" },
      sent: { rest: "sentitems", ews: "sentitems" },
      sentitems: { rest: "sentitems", ews: "sentitems" },
      "sent items": { rest: "sentitems", ews: "sentitems" },
      drafts: { rest: "drafts", ews: "drafts" },
      junk: { rest: "junkemail", ews: "junkemail" },
      junkemail: { rest: "junkemail", ews: "junkemail" },
      deleted: { rest: "deleteditems", ews: "deleteditems" },
      deleteditems: { rest: "deleteditems", ews: "deleteditems" },
      archive: { rest: "archive", ews: "archive" }
    };
    if (table[key]) {
      return { input: raw, rest: table[key].rest, ews: table[key].ews, distinguished: true };
    }
    return { input: raw, rest: null, ews: null, distinguished: false };
  }

  function clampTop(value) {
    var number = Number(value);
    if (!isFinite(number) || number <= 0) return 10;
    return Math.max(1, Math.min(50, Math.floor(number)));
  }

  function pageLocation() {
    try {
      return {
        host: String(location.hostname || "").toLowerCase(),
        href: String(location.href || ""),
        path: String(location.pathname || "")
      };
    } catch (error) {
      return { host: "", href: "", path: "" };
    }
  }

  function pageKind() {
    var where = pageLocation();
    var host = where.host;
    if (host === "login.microsoftonline.com" || host === "login.microsoft.com" || host === "login.windows.net" || host.indexOf("login.microsoftonline.com") >= 0) {
      return "login";
    }
    if (host === "outlook.office.com" || host === "outlook.office365.com") return "owa";
    if (!host) return "unknown";
    return "other";
  }

  function originAllowed() {
    var host = pageLocation().host;
    return host === "outlook.office.com" || host === "outlook.office365.com";
  }

  function failLabel(error) {
    if (!error) return "error";
    if (error.status) return String(error.status);
    if (error.code) return String(error.code);
    return "error";
  }

  function isSessionError(error) {
    if (!error) return false;
    return error.code === "session_expired" || error.status === 401 || error.status === 440;
  }

  function isNotFound(error) {
    if (!error) return false;
    return error.status === 404 || error.code === "not_found" || error.code === "ErrorItemNotFound";
  }

  function readCookie(name) {
    try {
      if (typeof document === "undefined" || !document.cookie) return null;
      var parts = String(document.cookie).split("; ");
      for (var i = 0; i < parts.length; i++) {
        var eq = parts[i].indexOf("=");
        if (eq < 0) continue;
        var key = decodeURIComponent(parts[i].slice(0, eq));
        if (key === name) return decodeURIComponent(parts[i].slice(eq + 1));
      }
    } catch (error) {}
    return null;
  }

  function owaHeaders(action) {
    var headers = {
      "Content-Type": "application/json; charset=utf-8",
      Accept: "application/json",
      Action: action,
      "X-Requested-With": "XMLHttpRequest"
    };
    var canary = readCookie("X-OWA-CANARY");
    if (canary) headers["X-OWA-CANARY"] = canary;
    return headers;
  }

  async function fetchJSON(path, options) {
    if (!originAllowed()) {
      var originError = new Error("origin");
      originError.code = "origin";
      throw originError;
    }
    var url = new URL(path, location.origin);
    var host = url.hostname.toLowerCase();
    if (host !== "outlook.office.com" && host !== "outlook.office365.com") {
      var blocked = new Error("blocked_host");
      blocked.code = "blocked_host";
      throw blocked;
    }
    var response = await fetch(url.toString(), Object.assign({ credentials: "include", redirect: "manual" }, options || {}));
    if (response.type === "opaqueredirect" || (response.status >= 300 && response.status < 400)) {
      var redirectError = new Error("session_expired");
      redirectError.code = "session_expired";
      redirectError.status = response.status || 302;
      throw redirectError;
    }
    if (response.status === 401 || response.status === 440) {
      var sessionError = new Error("session_expired");
      sessionError.code = "session_expired";
      sessionError.status = response.status;
      throw sessionError;
    }
    var type = (response.headers.get("content-type") || "").toLowerCase();
    var text = await response.text();
    if (type.indexOf("json") < 0) {
      var nonJson = new Error("non_json");
      nonJson.code = "non_json";
      nonJson.status = response.status;
      throw nonJson;
    }
    var json;
    try {
      json = JSON.parse(text);
    } catch (error) {
      var badJson = new Error("bad_json");
      badJson.code = "bad_json";
      badJson.status = response.status;
      throw badJson;
    }
    if (typeof json === "string") {
      try { json = JSON.parse(json); } catch (error) {}
    }
    if (response.status >= 400) {
      var httpError = new Error("http_" + response.status);
      httpError.code = response.status === 404 ? "not_found" : "http";
      httpError.status = response.status;
      throw httpError;
    }
    return json;
  }

  async function ews(action, body) {
    var paths = [
      "/owa/service.svc?action=" + encodeURIComponent(action) + "&app=Mail",
      "/owa/0/service.svc?action=" + encodeURIComponent(action) + "&app=Mail"
    ];
    var last;
    for (var i = 0; i < paths.length; i++) {
      try {
        return await fetchJSON(paths[i], {
          method: "POST",
          headers: owaHeaders(action),
          body: JSON.stringify(body)
        });
      } catch (error) {
        if (isSessionError(error)) throw error;
        last = error;
      }
    }
    throw last || new Error("ews_failed");
  }

  function unwrapEws(json) {
    var items = (((json || {}).Body || {}).ResponseMessages || {}).Items || [];
    var first = items[0] || {};
    if (first.ResponseClass && first.ResponseClass !== "Success") {
      var error = new Error(first.ResponseCode || "ews_error");
      error.code = first.ResponseCode || "ews_error";
      if (first.ResponseCode === "ErrorAccessDenied") error.code = "session_expired";
      throw error;
    }
    var list = (first.RootFolder && first.RootFolder.Items) || first.Items || [];
    return Array.isArray(list) ? list : [];
  }

  function findItemBody(folder, top, unread) {
    var body = {
      __type: "FindItemJsonRequest:#Exchange",
      Header: {
        __type: "JsonRequestHeaders:#Exchange",
        RequestServerVersion: "V2018_01_08"
      },
      Body: {
        __type: "FindItemRequest:#Exchange",
        ItemShape: {
          __type: "ItemResponseShape:#Exchange",
          BaseShape: "Default",
          AdditionalProperties: [
            { __type: "PropertyUri:#Exchange", FieldURI: "item:Preview" },
            { __type: "PropertyUri:#Exchange", FieldURI: "item:ConversationId" }
          ]
        },
        ParentFolderIds: [{ __type: "DistinguishedFolderId:#Exchange", Id: folder.ews }],
        Traversal: "Shallow",
        Paging: {
          __type: "IndexedPageView:#Exchange",
          BasePoint: "Beginning",
          Offset: 0,
          MaxEntriesReturned: top
        },
        SortOrder: [{
          __type: "SortResults:#Exchange",
          Order: "Descending",
          Path: { __type: "PropertyUri:#Exchange", FieldURI: "item:DateTimeReceived" }
        }]
      }
    };
    if (unread) {
      body.Body.Restriction = {
        __type: "RestrictionType:#Exchange",
        IsEqualTo: {
          __type: "IsEqualToType:#Exchange",
          Item: { __type: "PropertyUri:#Exchange", FieldURI: "message:IsRead" },
          FieldURIOrConstant: {
            __type: "FieldURIOrConstantType:#Exchange",
            Constant: { __type: "ConstantValueType:#Exchange", Value: "false" }
          }
        }
      };
    }
    return body;
  }

  function getItemBody(id) {
    return {
      __type: "GetItemJsonRequest:#Exchange",
      Header: {
        __type: "JsonRequestHeaders:#Exchange",
        RequestServerVersion: "V2018_01_08"
      },
      Body: {
        __type: "GetItemRequest:#Exchange",
        ItemShape: {
          __type: "ItemResponseShape:#Exchange",
          BaseShape: "Default",
          BodyType: "Text",
          AdditionalProperties: [
            { __type: "PropertyUri:#Exchange", FieldURI: "item:Preview" },
            { __type: "PropertyUri:#Exchange", FieldURI: "item:ConversationId" },
            { __type: "PropertyUri:#Exchange", FieldURI: "item:Attachments" }
          ]
        },
        ItemIds: [{ __type: "ItemId:#Exchange", Id: id }]
      }
    };
  }

  async function findRestFolderId(displayName) {
    var prefixes = ["/api/v2.0", "/owa/0/api/v2.0"];
    var last;
    for (var i = 0; i < prefixes.length; i++) {
      try {
        var json = await fetchJSON(prefixes[i] + "/me/mailfolders?$top=100&$select=Id,DisplayName", {
          headers: { Accept: "application/json" }
        });
        var value = json.value || json.Value || [];
        if (!Array.isArray(value)) value = [];
        var want = displayName.toLowerCase();
        for (var j = 0; j < value.length; j++) {
          if (String(value[j].DisplayName || "").toLowerCase() === want && value[j].Id) return value[j].Id;
        }
        var missing = new Error("folder_missing");
        missing.code = "folder_missing";
        throw missing;
      } catch (error) {
        if (isSessionError(error) || error.code === "folder_missing") throw error;
        last = error;
      }
    }
    throw last || new Error("folder_lookup_failed");
  }

  async function restMessages(folder, top, unread, trace) {
    var folderSegment = folder.rest;
    if (!folderSegment) folderSegment = await findRestFolderId(folder.input);
    var select = "Id,ConversationId,Subject,From,ToRecipients,ReceivedDateTime,BodyPreview,IsRead,HasAttachments,Importance";
    var filter = unread ? "&$filter=IsRead eq false" : "";
    var suffix = "/me/mailfolders/" + encodeURIComponent(folderSegment) + "/messages?$top=" + top + "&$orderby=ReceivedDateTime desc&$select=" + select + filter;
    var prefixes = ["/api/v2.0", "/owa/0/api/v2.0"];
    var last;
    for (var i = 0; i < prefixes.length; i++) {
      var path = prefixes[i] + suffix;
      try {
        var json = await fetchJSON(path, { headers: { Accept: "application/json" } });
        var value = json.value || json.Value || [];
        if (!Array.isArray(value)) value = [];
        trace.attempted.push("internalFetchProvider(ok)");
        trace.anchors.push({ field: "messages", via: "internal-api", selector: path.split("?")[0], matched: value.length });
        trace.provider = "internalFetchProvider";
        return value.map(adaptRestMessage);
      } catch (error) {
        if (isSessionError(error) || error.code === "folder_missing") throw error;
        trace.attempted.push("internalFetchProvider(failed: " + failLabel(error) + ")");
        last = error;
      }
    }
    throw last || new Error("rest_failed");
  }

  async function restMe(trace) {
    var paths = [
      "/api/v2.0/me?$select=DisplayName,Mail,UserPrincipalName",
      "/owa/0/api/v2.0/me?$select=DisplayName,Mail,UserPrincipalName"
    ];
    var last;
    for (var i = 0; i < paths.length; i++) {
      try {
        var json = await fetchJSON(paths[i], { headers: { Accept: "application/json" } });
        trace.attempted.push("internalFetchProvider(ok)");
        trace.anchors.push({ field: "me", via: "internal-api", selector: paths[i].split("?")[0], matched: 1 });
        trace.provider = "internalFetchProvider";
        return adaptRestUser(json);
      } catch (error) {
        if (isSessionError(error)) throw error;
        trace.attempted.push("internalFetchProvider(failed: " + failLabel(error) + ")");
        last = error;
      }
    }
    throw last || new Error("me_failed");
  }

  async function restDetail(id, trace) {
    var select = "Id,ConversationId,Subject,From,ToRecipients,CcRecipients,ReceivedDateTime,BodyPreview,IsRead,HasAttachments,Importance,Body";
    var prefixes = ["/api/v2.0", "/owa/0/api/v2.0"];
    var queries = [
      "$select=" + select + "&$expand=Attachments($select=Name,Size,ContentType)",
      "$select=" + select
    ];
    var last;
    for (var i = 0; i < prefixes.length; i++) {
      for (var q = 0; q < queries.length; q++) {
        var path = prefixes[i] + "/me/messages/" + encodeURIComponent(id) + "?" + queries[q];
        try {
          var json = await fetchJSON(path, { headers: { Accept: "application/json" } });
          trace.attempted.push("internalFetchProvider(ok)");
          trace.anchors.push({ field: "message", via: "internal-api", selector: path.split("?")[0], matched: 1 });
          trace.provider = "internalFetchProvider";
          return adaptRestDetail(json);
        } catch (error) {
          if (isSessionError(error)) throw error;
          trace.attempted.push("internalFetchProvider(failed: " + failLabel(error) + ")");
          last = error;
        }
      }
    }
    throw last || new Error("detail_failed");
  }

  function allDocuments() {
    var docs = [];
    if (typeof document !== "undefined" && document) docs.push(document);
    if (!docs.length || !document.querySelectorAll) return docs;
    var frames = document.querySelectorAll("iframe");
    for (var i = 0; i < frames.length; i++) {
      try {
        if (frames[i].contentDocument) docs.push(frames[i].contentDocument);
      } catch (error) {}
    }
    return docs;
  }

  function matchEmail(text) {
    var matched = String(text || "").match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i);
    return matched ? matched[0] : "";
  }

  function domMe(trace) {
    var docs = allDocuments();
    for (var d = 0; d < docs.length; d++) {
      var nodes = docs[d].querySelectorAll ? docs[d].querySelectorAll("[aria-label]") : [];
      for (var i = 0; i < nodes.length; i++) {
        var label = nodes[i].getAttribute("aria-label") || "";
        var email = matchEmail(label);
        if (!email) continue;
        var name = label.replace(email, "").replace(/帐户管理器|账户管理器|账号管理器|Account manager/ig, "").replace(/[·,，|]/g, " ").replace(/\s+/g, " ").trim();
        trace.attempted.push("domProvider(ok)");
        trace.anchors.push({ field: "address", via: "aria-label", selector: "[aria-label]", matched: 1 });
        trace.provider = "domProvider";
        return {
          displayName: name || email,
          address: email,
          tenant: tenantFromAddress(email),
          loggedIn: true
        };
      }
    }
    trace.attempted.push("domProvider(failed: no account label)");
    return null;
  }

  function fnv(text) {
    var hash = 2166136261;
    for (var i = 0; i < text.length; i++) {
      hash ^= text.charCodeAt(i);
      hash = Math.imul(hash, 16777619);
    }
    return (hash >>> 0).toString(16);
  }

  function ariaText(el, pattern) {
    var nodes = [el];
    if (el.querySelectorAll) nodes = nodes.concat(Array.prototype.slice.call(el.querySelectorAll("[aria-label]")));
    for (var i = 0; i < nodes.length; i++) {
      var text = nodes[i].getAttribute ? (nodes[i].getAttribute("aria-label") || "") : "";
      if (pattern.test(text)) return text.replace(pattern, "").trim();
    }
    return "";
  }

  function parseMailRow(el, trace) {
    var role = el.getAttribute ? (el.getAttribute("role") || "") : "";
    if (role !== "option" && role !== "listitem" && role !== "row") return null;
    var label = (el.getAttribute("aria-label") || "").trim();
    if (!label || /^(主题|发件人|收件人|时间|Subject|From|Received)$/i.test(label)) return null;
    var fromName = ariaText(el, /^(发件人|寄件者|From)\s*[:：]?\s*/i);
    var subject = ariaText(el, /^(主题|主旨|Subject)\s*[:：]?\s*/i);
    var blob = label;
    var unread = /未读|Unread/i.test(blob);
    var hasAttachments = /附件|Attachment/i.test(blob);
    var heuristic = false;
    if (!subject) {
      var parts = label.split(/\s*[,，]\s*/).map(function (part) { return part.trim(); }).filter(Boolean);
      var skip = /^(未读|已读|Unread|Read|有附件|附件|Attachment|Attachments?)$/i;
      var content = parts.filter(function (part) {
        return !skip.test(part) && !/^\d{1,2}:\d{2}/.test(part) && !/^(上午|下午|昨天|今天|Yesterday|Today)/.test(part);
      });
      if (!fromName && content.length) fromName = content[0];
      if (content.length >= 2) subject = content.slice(1).join(", ");
      else subject = label;
      heuristic = true;
    }
    if (heuristic && trace && trace.warnings.indexOf("subject 字段回退到文本启发式") < 0) {
      trace.warnings.push("subject 字段回退到文本启发式");
    }
    return {
      id: "dom:" + fnv(label),
      fromName: fromName,
      subject: subject,
      unread: unread,
      hasAttachments: hasAttachments,
      bodyPreview: "",
      receivedDateTime: null
    };
  }

  function domMessages(top, trace) {
    var docs = allDocuments();
    var rows = [];
    for (var d = 0; d < docs.length && rows.length < top; d++) {
      var doc = docs[d];
      if (!doc.querySelectorAll) continue;
      var lists = doc.querySelectorAll('[role="listbox"], [role="list"], [role="grid"]');
      var scopes = lists.length ? Array.prototype.slice.call(lists) : [doc];
      for (var s = 0; s < scopes.length && rows.length < top; s++) {
        var items = scopes[s].querySelectorAll('[role="option"], [role="listitem"], [role="row"]');
        for (var i = 0; i < items.length && rows.length < top && i < 80; i++) {
          var parsed = parseMailRow(items[i], trace);
          if (parsed) rows.push(parsed);
        }
      }
    }
    if (!rows.length) {
      trace.attempted.push("domProvider(failed: no rows)");
      return null;
    }
    trace.attempted.push("domProvider(ok)");
    trace.warnings.push("domProvider 读取的是当前页面上的列表，不会切换文件夹");
    trace.anchors.push({
      field: "messages",
      via: "aria",
      selector: "[role=option], [role=listitem]",
      matched: rows.length
    });
    trace.provider = "domProvider";
    return rows.slice(0, top).map(adaptDomItem);
  }

  function findReadingPane() {
    var docs = allDocuments();
    for (var d = 0; d < docs.length; d++) {
      var doc = docs[d];
      if (!doc.querySelector) continue;
      var pane = doc.querySelector("[aria-label*='邮件正文'], [aria-label*='Message body'], [role='document']");
      if (pane) return pane;
      var main = doc.querySelector("[role='main']");
      if (main) return main;
    }
    return null;
  }

  function domDetail(id, trace) {
    var cached = cache.get(id);
    if (!cached) return null;
    var message = JSON.parse(JSON.stringify(cached));
    message.cc = message.cc || [];
    message.attachments = message.attachments || [];
    var pane = findReadingPane();
    if (pane) {
      var heading = pane.querySelector ? pane.querySelector("h1, h2, [role=heading]") : null;
      var bodyEl = pane.querySelector ? pane.querySelector("[aria-label*='邮件正文'], [aria-label*='Message body'], [role=document]") : null;
      if (heading && heading.textContent) message.subject = heading.textContent.trim() || message.subject;
      if (bodyEl) {
        message.body = { contentType: "text", content: (bodyEl.innerText || bodyEl.textContent || "").trim() };
        trace.anchors.push({ field: "body", via: "aria", selector: "[role=document]", matched: 1 });
      }
    }
    if (!message.body) {
      message.body = { contentType: "text", content: "" };
      trace.warnings.push("domProvider 没有打开阅读窗格，正文为空");
    }
    trace.attempted.push("domProvider(ok)");
    trace.provider = "domProvider";
    return message;
  }

  function remember(messages) {
    for (var i = 0; i < messages.length; i++) cache.set(messages[i].id, messages[i]);
  }

  function sessionExpired(trace, started, target, includeDebug) {
    return finish(401, { error: "session_expired", message: "Outlook 会话已失效，请在窗口中重新登录" }, trace, started, target, false, includeDebug);
  }

  function notLoggedIn(trace, started, target, includeDebug) {
    return finish(401, { error: "not_logged_in", message: "尚未登录 Outlook" }, trace, started, target, false, includeDebug);
  }

  async function extractMe(params) {
    var started = nowMs();
    var trace = freshTrace(params);
    var includeDebug = !!params.debug;
    if (pageKind() === "login") return notLoggedIn(trace, started, "me", includeDebug);
    try {
      var user = null;
      try {
        user = await restMe(trace);
      } catch (error) {
        if (isSessionError(error)) return sessionExpired(trace, started, "me", includeDebug);
      }
      if (!user) user = domMe(trace);
      if (!user) {
        if (pageKind() !== "owa") return notLoggedIn(trace, started, "me", includeDebug);
        return finish(500, { error: "extract_failed", message: "无法识别当前登录用户" }, trace, started, "me", false, includeDebug);
      }
      return finish(200, user, trace, started, "me", true, includeDebug);
    } catch (error) {
      if (isSessionError(error)) return sessionExpired(trace, started, "me", includeDebug);
      return finish(500, { error: "extract_failed", message: "无法识别当前登录用户" }, trace, started, "me", false, includeDebug);
    }
  }

  async function extractMessages(params) {
    var started = nowMs();
    var trace = freshTrace(params);
    var includeDebug = !!params.debug;
    var folder = mapFolder(params.folder || "inbox");
    var top = clampTop(params.top);
    var unread = !!params.unread;
    if (pageKind() === "login") return notLoggedIn(trace, started, "messages", includeDebug);
    try {
      var messages = null;
      try {
        messages = await restMessages(folder, top, unread, trace);
      } catch (error) {
        if (isSessionError(error)) return sessionExpired(trace, started, "messages", includeDebug);
        if (error.code === "folder_missing") {
          return finish(404, { error: "not_found", message: "找不到文件夹" }, trace, started, "messages", false, includeDebug);
        }
      }
      if (!messages && folder.ews) {
        try {
          var json = await ews("FindItem", findItemBody(folder, top, unread));
          var items = unwrapEws(json);
          messages = items.map(adaptEwsMessage);
          trace.attempted.push("internalFetchProvider(ok)");
          trace.anchors.push({ field: "messages", via: "internal-api", selector: "service.svc?action=FindItem", matched: messages.length });
          trace.provider = "internalFetchProvider";
        } catch (error) {
          if (isSessionError(error)) return sessionExpired(trace, started, "messages", includeDebug);
          trace.attempted.push("internalFetchProvider(failed: " + failLabel(error) + ")");
        }
      }
      if (!messages) {
        messages = domMessages(top, trace);
      }
      if (!messages) {
        if (pageKind() !== "owa") return notLoggedIn(trace, started, "messages", includeDebug);
        return finish(500, { error: "extract_failed", message: "抽取邮件失败" }, trace, started, "messages", false, includeDebug);
      }
      remember(messages);
      return finish(200, { folder: folder.input, count: messages.length, messages: messages }, trace, started, "messages", true, includeDebug);
    } catch (error) {
      if (isSessionError(error)) return sessionExpired(trace, started, "messages", includeDebug);
      return finish(500, { error: "extract_failed", message: "抽取邮件失败" }, trace, started, "messages", false, includeDebug);
    }
  }

  function detailFromCache(id, trace, warning) {
    var cached = cache.get(id);
    if (!cached) return null;
    var message = JSON.parse(JSON.stringify(cached));
    message.cc = message.cc || [];
    message.body = message.body || { contentType: "text", content: "" };
    message.attachments = message.attachments || [];
    if (warning) trace.warnings.push(warning);
    trace.attempted.push("internalFetchProvider(failed: detail_fallback_cache)");
    trace.provider = trace.provider || "internalFetchProvider";
    return message;
  }

  async function extractMessage(params) {
    var started = nowMs();
    var trace = freshTrace(params);
    var includeDebug = !!params.debug;
    var id = String(params.id || "");
    if (!id) return finish(404, { error: "not_found", message: "找不到这封邮件" }, trace, started, "message", false, includeDebug);
    if (pageKind() === "login") return notLoggedIn(trace, started, "message", includeDebug);
    if (id.indexOf("dom:") === 0) {
      var dom = domDetail(id, trace);
      if (!dom) return finish(404, { error: "not_found", message: "找不到这封邮件" }, trace, started, "message", false, includeDebug);
      return finish(200, dom, trace, started, "message", true, includeDebug);
    }
    try {
      var message = null;
      try {
        message = await restDetail(id, trace);
      } catch (error) {
        if (isSessionError(error)) return sessionExpired(trace, started, "message", includeDebug);
        if (!isNotFound(error)) {
          // Keep going to the OWA service endpoint.
        } else {
          trace.attempted.push("internalFetchProvider(failed: 404)");
        }
      }
      if (!message) {
        try {
          var json = await ews("GetItem", getItemBody(id));
          var items = unwrapEws(json);
          if (!items.length) {
            var empty = new Error("not_found");
            empty.code = "not_found";
            throw empty;
          }
          message = adaptEwsDetail(items[0]);
          trace.attempted.push("internalFetchProvider(ok)");
          trace.anchors.push({ field: "message", via: "internal-api", selector: "service.svc?action=GetItem", matched: 1 });
          trace.provider = "internalFetchProvider";
        } catch (error) {
          if (isSessionError(error)) return sessionExpired(trace, started, "message", includeDebug);
          if (isNotFound(error)) {
            trace.attempted.push("internalFetchProvider(failed: 404)");
          } else {
            trace.attempted.push("internalFetchProvider(failed: " + failLabel(error) + ")");
          }
        }
      }
      if (!message) {
        message = detailFromCache(id, trace, "详情接口不可用，返回了列表里缓存的字段，正文可能为空");
      }
      if (!message) return finish(404, { error: "not_found", message: "找不到这封邮件" }, trace, started, "message", false, includeDebug);
      cache.set(message.id, message);
      return finish(200, message, trace, started, "message", true, includeDebug);
    } catch (error) {
      if (isSessionError(error)) return sessionExpired(trace, started, "message", includeDebug);
      return finish(500, { error: "extract_failed", message: "抽取邮件失败" }, trace, started, "message", false, includeDebug);
    }
  }

  function statusBody(params) {
    var loggedIn = lastLoggedIn && pageKind() !== "login";
    var body = {
      loggedIn: loggedIn,
      provider: lastProvider,
      adapterVersion: ADAPTER_VERSION,
      lastExtract: lastExtract
    };
    if (params && params.debug) {
      body._debug = {
        provider: lastProvider,
        durationMs: lastExtract ? lastExtract.durationMs : 0,
        attempted: [],
        anchors: [],
        warnings: [],
        correlationId: params.correlationId || null,
        adapterVersion: ADAPTER_VERSION
      };
    }
    return { status: 200, body: body, trace: { provider: lastProvider, durationMs: 0, attempted: [], anchors: [], warnings: [] } };
  }

  function debugDom(params) {
    var selector = params.selector || "body";
    var element;
    try {
      element = document.querySelector(selector);
    } catch (error) {
      return { status: 400, body: { error: "extract_failed", message: "选择器无效" } };
    }
    if (!element) return { status: 404, body: { error: "not_found", message: "没有匹配的节点" } };
    var html = redact(element.outerHTML || "");
    var limit = 200000;
    return {
      status: 200,
      body: {
        selector: selector,
        truncated: html.length > limit,
        html: html.slice(0, limit)
      }
    };
  }

  function explicitRole(el) {
    return el.getAttribute ? (el.getAttribute("role") || "") : "";
  }

  function implicitRole(el) {
    var tag = (el.tagName || "").toUpperCase();
    var map = { MAIN: "main", NAV: "navigation", HEADER: "banner", BUTTON: "button", A: "link", H1: "heading", H2: "heading", H3: "heading", INPUT: "textbox", TEXTAREA: "textbox" };
    return map[tag] || "";
  }

  function headingLevel(el) {
    var tag = (el.tagName || "").toUpperCase();
    if (tag === "H1") return 1;
    if (tag === "H2") return 2;
    if (tag === "H3") return 3;
    var level = el.getAttribute ? el.getAttribute("aria-level") : "";
    return level ? Number(level) : 0;
  }

  function ariaNode(el, depth, budget) {
    if (!el || el.nodeType !== 1 || budget.left <= 0 || depth > 14) return null;
    var role = explicitRole(el);
    var implied = implicitRole(el);
    var name = el.getAttribute ? (el.getAttribute("aria-label") || "") : "";
    if (name.length > 300) name = name.slice(0, 300);
    var keep = !!(role || name || implied);
    var childNodes = [];
    var kids = el.children ? Array.prototype.slice.call(el.children) : [];
    for (var i = 0; i < kids.length; i++) {
      var child = ariaNode(kids[i], depth + 1, budget);
      if (!child) continue;
      if (child.promoted) childNodes = childNodes.concat(child.nodes);
      else childNodes.push(child);
    }
    if (!keep) {
      if (!childNodes.length) return null;
      return { promoted: true, nodes: childNodes };
    }
    if (budget.left <= 0) return null;
    budget.left -= 1;
    var node = { role: role || implied || "generic", name: name };
    var level = headingLevel(el);
    if (level) node.level = level;
    if (childNodes.length) node.children = childNodes;
    return node;
  }

  function debugAria() {
    var budget = { left: 800 };
    var forest = [];
    var docs = allDocuments();
    for (var i = 0; i < docs.length; i++) {
      var root = docs[i].body || docs[i].documentElement;
      var node = ariaNode(root, 0, budget);
      if (!node) continue;
      if (node.promoted) forest = forest.concat(node.nodes);
      else forest.push(node);
    }
    return { status: 200, body: { tree: forest } };
  }

  async function debugEval(params) {
    if (!params.allowEval) {
      return { status: 403, body: { error: "eval_disabled", message: "debug/eval 默认关闭，在 ~/.owa-bridge/config.json 设置 debugEvalEnabled 为 true 后重启" } };
    }
    var source = String(params.code || "");
    if (!source) return { status: 400, body: { error: "extract_failed", message: "缺少 code 参数" } };
    try {
      var AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
      var fn = new AsyncFunction("return (" + source + ");");
      var value = await fn();
      var safe;
      try {
        safe = JSON.parse(redact(JSON.stringify(value == null ? null : value)));
      } catch (error) {
        safe = redact(String(value));
      }
      return { status: 200, body: { result: safe } };
    } catch (error) {
      return { status: 500, body: { error: "extract_failed", message: redact(String(error && error.message || "执行失败")).slice(0, 300) } };
    }
  }

  async function extractTrace(params) {
    var target = params.target || "messages";
    var next = Object.assign({}, params, { debug: true });
    var response;
    if (target === "me") response = await extractMe(next);
    else if (target === "message") response = await extractMessage(next);
    else response = await extractMessages(next);
    return {
      status: response.status,
      body: {
        target: target === "message" || target === "me" ? target : "messages",
        result: response.body,
        trace: response.trace || null
      },
      trace: response.trace || null
    };
  }

  async function dispatch(op, params) {
    var input = params || {};
    try {
      if (op === "me") return await extractMe(input);
      if (op === "messages") return await extractMessages(input);
      if (op === "message") return await extractMessage(input);
      if (op === "status") return statusBody(input);
      if (op === "dom") return debugDom(input);
      if (op === "aria") return debugAria();
      if (op === "extract") return await extractTrace(input);
      if (op === "eval") return await debugEval(input);
      return { status: 404, body: { error: "not_found", message: "未知操作" } };
    } catch (error) {
      return { status: 500, body: { error: "extract_failed", message: "抽取失败" } };
    }
  }

  var api = {
    __installed: true,
    dispatch: dispatch,
    version: ADAPTER_VERSION,
    _test: {
      redact: redact,
      adaptRestUser: adaptRestUser,
      adaptRestMessage: adaptRestMessage,
      adaptRestDetail: adaptRestDetail,
      adaptEwsMessage: adaptEwsMessage,
      adaptEwsDetail: adaptEwsDetail,
      adaptDomItem: adaptDomItem,
      mapFolder: mapFolder,
      clampTop: clampTop,
      toISO: toISO,
      person: person
    }
  };
  globalThis.__owaBridge = api;
})();
