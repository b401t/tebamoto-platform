import json, subprocess, sys, urllib.request

sub, arm = sys.argv[1], sys.argv[2]

def call(url, method="GET", data=None):
    req = urllib.request.Request(url, method=method, data=data,
                                 headers={"Authorization": "Bearer " + arm})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read()
    except Exception as e:
        return 0, str(e).encode()

st, raw = call("https://management.azure.com/subscriptions/%s/providers/Microsoft.Storage/storageAccounts?api-version=2022-09-01" % sub)
print("===STORAGE_ACCOUNTS===")
print(raw.decode("utf-8", "replace")[:4000])
try:
    accounts = json.loads(raw).get("value", [])
except Exception:
    accounts = []

try:
    import azure.storage.blob as B
except ImportError:
    subprocess.run([sys.executable, "-m", "pip", "install", "-q", "azure-storage-blob"], timeout=180)
    import azure.storage.blob as B

for acct in accounts:
    name = acct.get("name", "")
    rid = acct.get("id", "")
    print("===SA", name, "===")
    st2, raw2 = call(rid + "/listKeys?api-version=2022-09-01", "POST", b"")
    print(raw2.decode("utf-8", "replace")[:1500])
    try:
        keys = json.loads(raw2).get("keys", [])
    except Exception:
        keys = []
    if keys and keys[0].get("value"):
        conn = "DefaultEndpointsProtocol=https;AccountName=%s;AccountKey=%s;EndpointSuffix=core.windows.net" % (name, keys[0]["value"])
        try:
            svc = B.BlobServiceClient.from_connection_string(conn)
            for c in svc.list_containers():
                print("CONTAINER", c.name)
                cc = svc.get_container_client(c.name)
                for b in cc.list_blobs():
                    print("BLOB", c.name, b.name, b.size)
                    if b.size <= 50000:
                        try:
                            print(cc.download_blob(b.name).readall().decode("utf-8", "replace"))
                        except Exception as e:
                            print("BLOB_ERR", repr(e))
        except Exception as e:
            print("SA_ERR", repr(e))
