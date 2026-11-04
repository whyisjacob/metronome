"""Report App Store review status and (MODE=submit) resubmit the 1.0 version.
Uses the ASC API key from CI secrets. Prints no secrets."""
import os, sys, time, json, jwt, requests

APP = "6808669191"
MODE = os.environ.get("MODE", "status")
BUILD = os.environ.get("BUILD", "42")
B = "https://api.appstoreconnect.apple.com"

def tok():
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100,
                       "aud": "appstoreconnect-v1"}, os.environ["ASC_KEY_P8"], algorithm="ES256",
                      headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
H = {"Authorization": f"Bearer {tok()}", "Content-Type": "application/json"}

def call(method, path, body=None, ok=(200, 201, 204)):
    r = requests.request(method, B + path, headers=H, json=body)
    if r.status_code not in ok:
        print(f"!! {method} {path} -> {r.status_code}: {r.text[:1500]}"); sys.exit(1)
    return r.json() if r.text else {}

def status():
    v = call("GET", f"/v1/apps/{APP}/appStoreVersions?include=build&limit=10")
    builds = {b["id"]: b["attributes"].get("version") for b in v.get("included", []) if b["type"] == "builds"}
    vers = []
    for d in v["data"]:
        a = d["attributes"]; bid = (d["relationships"]["build"].get("data") or {}).get("id")
        print(f"VERSION {a['versionString']} state={a.get('appStoreState')} / {a.get('appVersionState')} build={builds.get(bid)} id={d['id']}")
        vers.append(d)
    s = call("GET", f"/v1/apps/{APP}/reviewSubmissions?limit=10&include=items")
    for d in s["data"]:
        a = d["attributes"]
        print(f"SUBMISSION {d['id']} state={a.get('state')} submitted={a.get('submittedDate')}")
    b = call("GET", f"/v1/builds?filter[app]={APP}&sort=-uploadedDate&limit=6")
    for d in b["data"]:
        a = d["attributes"]
        print(f"BUILD {a['version']} processing={a.get('processingState')} expired={a.get('expired')} uploaded={a.get('uploadedDate')} id={d['id']}")
    return vers, s["data"], b["data"]

vers, subs, builds = status()
if MODE != "submit":
    sys.exit(0)

ver = next(d for d in vers if d["attributes"].get("appStoreState") not in ("READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION"))
# 1. Cancel any open submission (stuck in WAITING_FOR_REVIEW etc.)
for d in subs:
    st = d["attributes"].get("state")
    if st in ("WAITING_FOR_REVIEW", "IN_REVIEW", "READY_FOR_REVIEW", "UNRESOLVED_ISSUES"):
        print(f"cancel {d['id']} ({st})")
        call("PATCH", f"/v1/reviewSubmissions/{d['id']}", {"data": {"type": "reviewSubmissions", "id": d["id"], "attributes": {"canceled": True}}})
for _ in range(40):
    s = call("GET", f"/v1/apps/{APP}/reviewSubmissions?limit=10")["data"]
    if not any(d["attributes"].get("state") in ("CANCELING", "WAITING_FOR_REVIEW", "IN_REVIEW") for d in s):
        break
    print("waiting for cancel..."); time.sleep(15)
# 2. Attach the build
bld = next(d for d in builds if d["attributes"]["version"] == BUILD)
call("PATCH", f"/v1/appStoreVersions/{ver['id']}/relationships/build", {"data": {"type": "builds", "id": bld["id"]}})
print(f"attached build {BUILD}")
# 3. New submission with the version, then submit
open_sub = next((d for d in s if d["attributes"].get("state") == "READY_FOR_REVIEW"), None)
if open_sub:
    sid = open_sub["id"]
else:
    sid = call("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions", "attributes": {"platform": "IOS"},
               "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]["id"]
items = call("GET", f"/v1/reviewSubmissions/{sid}/items")["data"]
for attempt in range(8):
    if items: break
    r = requests.post(B + "/v1/reviewSubmissionItems", headers=H, json= {"data": {"type": "reviewSubmissionItems",
         "relationships": {"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sid}},
                           "appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver["id"]}}}}})
    print(f"add item attempt {attempt+1}: {r.status_code} {r.text[:300] if r.status_code >= 300 else ''}")
    if r.status_code < 300: break
    v = call("GET", f"/v1/appStoreVersions/{ver['id']}")["data"]["attributes"]
    print(f"  version state now {v.get('appStoreState')}; retry in 45s"); time.sleep(45)
else:
    sys.exit("could not add version to submission")
call("PATCH", f"/v1/reviewSubmissions/{sid}", {"data": {"type": "reviewSubmissions", "id": sid, "attributes": {"submitted": True}}})
print(f"SUBMITTED {sid}")
time.sleep(10)
status()
