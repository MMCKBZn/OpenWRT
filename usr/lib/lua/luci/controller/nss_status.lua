module("luci.controller.nss_status", package.seeall)
function index()
    entry({"admin", "nss_status"}, call("action_redirect"), _("NSS 状态"), 60).leaf = true
end
function action_redirect()
    luci.http.redirect("/cgi-bin/nss_status")
end
