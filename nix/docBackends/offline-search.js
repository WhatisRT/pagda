// Make agda-web-docs-lib's search work without a HTTP server.
//
// Browsers block fetch() for file:// resources, so search.js cannot load its
// index when the docs are opened directly. The offline doc backend embeds the
// index as a global (search-index.js sets window.__pagdaSearchData) and loads
// this shim before search.js; it intercepts the search-index fetches and serves
// them from memory. All other requests pass through unchanged.
(function () {
  var realFetch = typeof window.fetch === "function" ? window.fetch.bind(window) : null;
  window.fetch = function (input, init) {
    var url = String(typeof input === "string" ? input : (input && input.url) || "");
    var name = url.split("?")[0].split("#")[0].split("/").pop();
    if (name === "search-index.json" && window.__pagdaSearchData) {
      return Promise.resolve(new Response(JSON.stringify(window.__pagdaSearchData), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }));
    }
    // Chunked/metadata variants aren't emitted; 404 so search.js uses the index.
    if (name === "search-index-metadata.json" || /^search-index-.+\.json$/.test(name)) {
      return Promise.resolve(new Response("", { status: 404 }));
    }
    return realFetch ? realFetch(input, init) : Promise.reject(new Error("offline fetch: " + url));
  };
})();
