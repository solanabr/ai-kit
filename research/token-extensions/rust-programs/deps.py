import sys,json,urllib.request
def path(c):
    n=len(c)
    return f"{n}/{c}" if n<=2 else (f"3/{c[0]}/{c}" if n==3 else f"{c[:2]}/{c[2:4]}/{c}")
for arg in sys.argv[1:]:
    c,v=arg.split("@")
    for l in urllib.request.urlopen("https://index.crates.io/"+path(c)).read().decode().splitlines():
        j=json.loads(l)
        if j["vers"]==v:
            ds=[f'{d["name"]}{"(" + d["package"] + ")" if d.get("package") else ""} {d["req"]}{" opt" if d["optional"] else ""}' for d in j["deps"] if d["kind"]!="dev" and (d["name"].startswith(("spl","solana","anchor","pinocchio")) or d.get("package","").startswith(("spl","solana")))]
            print(f"== {c} {v} [{j.get('pubtime','')}]:", "; ".join(ds))
