"""Read-only TestFlight diagnostics; credentials stay in CI and never enter logs."""
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt


def main():
    now = int(time.time())
    token = jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600,
         "aud": "appstoreconnect-v1"},
        os.environ["ASC_KEY_P8"], algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )

    def get(path, **query):
        url = "https://api.appstoreconnect.apple.com/v1/" + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            print("Apple API error:", error.code, error.read().decode())
            raise SystemExit(1) from None

    apps = get("apps", **{"filter[bundleId]": "app.metronome.mobile"})["data"]
    assert len(apps) == 1, "Expected the existing Maelzel app"
    app = apps[0]
    print("App:", app["id"], app["attributes"]["name"])
    builds = get("builds", **{"filter[app]": app["id"], "sort": "-uploadedDate", "limit": 5,
                              "include": "buildBetaDetail,preReleaseVersion"})
    for build in builds["data"]:
        attrs = build["attributes"]
        print("BUILD", json.dumps({"id": build["id"], **{key: attrs.get(key) for key in
              ("version", "processingState", "expired", "uploadedDate", "usesNonExemptEncryption")}}))
        detail = get("builds/" + build["id"] + "/buildBetaDetail")["data"]
        print("BETA_STATE", json.dumps(detail["attributes"]))
    for group in get("apps/" + app["id"] + "/betaGroups")["data"]:
        attrs = group["attributes"]
        print("GROUP", json.dumps({"id": group["id"], **{key: attrs.get(key) for key in
              ("name", "isInternalGroup", "hasAccessToAllBuilds", "publicLinkEnabled")}}))
        versions = get("betaGroups/" + group["id"] + "/builds", limit=10)["data"]
        print("GROUP_BUILDS", [item["attributes"]["version"] for item in versions])


if __name__ == "__main__":
    main()
