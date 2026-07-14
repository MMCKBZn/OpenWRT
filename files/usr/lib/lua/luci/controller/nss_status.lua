module("luci.controller.nss_status", package.seeall)

function index()
    entry({"admin", "status", "nss"}, template("nss_status"), "NSS Status", 99).leaf = true
end
