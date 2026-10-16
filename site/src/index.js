// Serves the static site and exposes the R2 sound bucket at /sounds in the S3 ListObjectsV2
// format the StageKeys app reads (`GET /sounds/?list-type=2`, `GET /sounds/<key>`).
const PREFIX = "/sounds";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.hostname.startsWith("www.")) {
      url.hostname = url.hostname.slice(4);
      return Response.redirect(url.toString(), 301);
    }
    if (url.pathname === PREFIX || url.pathname.startsWith(`${PREFIX}/`)) {
      return sounds(request, env, url);
    }
    return env.ASSETS.fetch(request);
  },
};

async function sounds(request, env, url) {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response(null, { status: 405, headers: { Allow: "GET, HEAD" } });
  }
  const key = decodeURIComponent(url.pathname.slice(PREFIX.length + 1));
  if (!key) {
    if (url.searchParams.get("list-type") !== "2") return new Response("Not found", { status: 404 });
    return list(env, url.searchParams.get("continuation-token"));
  }
  const object = request.method === "HEAD" ? await env.SOUNDS.head(key) : await env.SOUNDS.get(key);
  if (!object) return new Response("Not found", { status: 404 });
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("etag", object.httpEtag);
  headers.set("cache-control", "public, max-age=300");
  return new Response(request.method === "HEAD" ? null : object.body, { headers });
}

async function list(env, token) {
  const page = await env.SOUNDS.list({ cursor: token || undefined, limit: 1000 });
  const contents = page.objects.map((o) =>
    `<Contents><Key>${xml(o.key)}</Key><LastModified>${o.uploaded.toISOString()}</LastModified>` +
    `<ETag>"${xml(o.etag)}"</ETag><Size>${o.size}</Size><StorageClass>STANDARD</StorageClass></Contents>`
  ).join("");
  const next = page.truncated ? `<NextContinuationToken>${xml(page.cursor)}</NextContinuationToken>` : "";
  const body = `<?xml version="1.0" encoding="UTF-8"?>` +
    `<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">` +
    `<Name>stagekeys-sounds</Name><KeyCount>${page.objects.length}</KeyCount><MaxKeys>1000</MaxKeys>` +
    `<IsTruncated>${page.truncated}</IsTruncated>${next}${contents}</ListBucketResult>`;
  return new Response(body, {
    headers: { "content-type": "application/xml", "cache-control": "no-cache" },
  });
}

function xml(text) {
  return text.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}
