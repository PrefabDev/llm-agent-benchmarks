# -*- coding: utf-8 -*-
"""Benchmark isolant l'effet de fenetres 32K et 64K : lecture d'un dossier >32K tokens.
API Ollama locale directe, sans outils ni navigateur. Python 3, standard library + tiktoken (facultatif).
Les reponses sont validees sur des cles imprevisibles dans des fiches dispersees.
Un seul essai ne constitue pas une preuve de superiorite generale.
"""
import argparse, csv, ctypes, hashlib, json, os, re, subprocess, sys, time
from pathlib import Path
from urllib.request import Request, urlopen

ROOT = Path(r"D:\IA\Benchmarks")
API = "http://127.0.0.1:11434"
MODELS = [("MoE32K", "qwen36-moe:32k", 32768),
          ("MoE64K", "qwen36-moe:64k", 65536)]
ENC = None

def api(path, obj=None, timeout=60):
    payload = None if obj is None else json.dumps(obj).encode("utf-8")
    req = Request(API + path, payload, {"Content-Type":"application/json"} if payload else {}, "POST" if payload else "GET")
    with urlopen(req, timeout=timeout) as result:
        return json.loads(result.read().decode("utf-8"))

def free_mb():
    class S(ctypes.Structure):
        _fields_ = [("dwLength",ctypes.c_ulong), ("dwMemoryLoad",ctypes.c_ulong),
                    ("ullTotalPhys",ctypes.c_ulonglong), ("ullAvailPhys",ctypes.c_ulonglong),
                    ("ullTotalPageFile",ctypes.c_ulonglong), ("ullAvailPageFile",ctypes.c_ulonglong),
                    ("ullTotalVirtual",ctypes.c_ulonglong), ("ullAvailVirtual",ctypes.c_ulonglong),
                    ("ullAvailExtendedVirtual",ctypes.c_ulonglong)]
    s = S(); s.dwLength = ctypes.sizeof(S)
    if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(s)):
        return round(s.ullAvailPhys / (1024*1024))
    return -1

def gpu_mb():
    try:
        text = subprocess.check_output(["nvidia-smi.exe","--query-gpu=memory.used","--format=csv,noheader,nounits"],
                                       text=True, timeout=6)
        return int(text.splitlines()[0].strip())
    except Exception: return -1

def token_estimate(prompt):
    global ENC
    if ENC is None:
        try:
            import tiktoken
            ENC = tiktoken.get_encoding("cl100k_base")
        except Exception:
            ENC = False
    if ENC:
        return len(ENC.encode(prompt))
    return round(len(prompt)/4)

def line(i):
    ident = "REF-%05d" % i
    key = "PB-" + hashlib.sha256(("prefa-2026-doc-"+ident).encode()).hexdigest()[:12].upper()
    classes = ["C25/30","C30/37","C35/45","C40/50"]
    faces = ["vue-coffrage","vue-levage","vue-ferraillage","vue-finition"]
    works = ["grutage","stockage","joint vertical","transport","traitement thermique"]
    # Des informations non interchangeables, et beaucoup de valeurs distractrices.
    return (f"{ident} | cle_controle={key} | panneau=PN-{i:05d} | beton={classes[i%4]} | "
        f"largeur={2500+(i*13)%1800}mm hauteur={1900+(i*17)%2000}mm epaisseur={160+(i*7)%160}mm | "
        f"operation={works[i%5]} | face={faces[i%4]} | nappe=HA{8+2*(i%4)} | "
        f"enrobage={20+i%25}mm | lot={i%31:02d} | qualite={i%13} | "
        f"notation: verifier la liaison des armatures, le jeu des reservations et la masse de levage ; "
        f"aucune conversion ni calcul ne permet de reconstituer la cle_controle.")

def make_prompt(n):
    positions = [max(1,round(n*p)) for p in (.018,.10,.40,.70,.97)]
    refs = ["REF-%05d" % p for p in positions]
    keys = {r: "PB-"+hashlib.sha256(("prefa-2026-doc-"+r).encode()).hexdigest()[:12].upper() for r in refs}
    task = ("Tu dois auditer un tres long registre technique de prefabrication, strictement fourni ici, "
        "sans utiliser d'outil, sans inventer de donnees. Chaque cle_controle est arbitraire et unique. "
        "Les autres lignes servent de distracteurs. Recopie les cles des CINQ fiches exactes citees "
        "dans la consigne finale. Reponds en un SEUL OBJET JSON, avec ces identifiants comme cles "
        "et leur cle_controle comme valeurs, sans commentaire.\n\n")
    corpus = "\n".join(line(i) for i in range(1,n+1))
    closing = ("\n\nFIN DU REGISTRE. CONSIGNE FINALE IMPERATIVE : "
        "Extrait exactement les champs cle_controle des fiches "
        + ", ".join(refs) + ". Renvoie uniquement un objet JSON a cinq proprietes.")
    return task+corpus+closing, keys

def build():
    # Recherche deterministe d'un dossier ~=41K tokens avec tiktoken (estimation).
    # La vraie mesure sera prompt_eval_count dans le resultat Ollama.
    lo,hi=350,1600
    while lo<hi:
        mid=(lo+hi)//2
        p,_=make_prompt(mid)
        if token_estimate(p)<41500: lo=mid+1
        else: hi=mid
    p,k=make_prompt(lo)
    return p,k,token_estimate(p),lo

def unload():
    for _,m,_ in MODELS:
        try: api("/api/generate",{"model":m,"keep_alive":0},timeout=45)
        except Exception as e: print("INFO dechargement",m,str(e)[:100],flush=True)
    time.sleep(2)

def warm(model,ctx):
    reply=api("/api/generate",{"model":model,"prompt":"OK","stream":False,
               "keep_alive":"30m","options":{"num_ctx":ctx,"num_predict":2}},timeout=400)
    if reply.get("error"): raise RuntimeError(reply["error"])
    active=api("/api/ps")
    selected=[x for x in active.get("models",[]) if x.get("name")==model or x.get("model")==model]
    if not selected: raise RuntimeError("Modele absent de /api/ps")
    live=selected[0].get("context_length")
    if live is not None and int(live)!=ctx: raise RuntimeError(f"Contexte Ollama inattendu: {live} != {ctx}")
    return live, round(selected[0].get("size_vram",0)/(1024*1024))

def worker(args):
    prompt=Path(args.prompt).read_text(encoding="utf-8")
    req={"model":args.model,"prompt":prompt,"stream":False,"keep_alive":"30m",
         "think":False,"format":"json",
         "options":{"num_ctx":args.ctx,"num_predict":320,"temperature":0,"seed":42}}
    try:
        reply=api("/api/generate",req,timeout=args.timeout*60+120)
        Path(args.output).write_text(json.dumps(reply,ensure_ascii=False,indent=2),encoding="utf-8")
        return 0
    except Exception as e:
        Path(args.output).write_text(json.dumps({"error":str(e)},ensure_ascii=False),encoding="utf-8")
        return 2

def extract(response,keys):
    content=response.get("response","") or ""
    try: dic=json.loads(content)
    except Exception:
        dic={}
        for ref in keys:
            found=re.search(re.escape(ref)+r'[^A-Z0-9]+(PB-[A-F0-9]{12})',content)
            if found: dic[ref]=found.group(1)
    return sum(1 for k,v in keys.items() if str(dic.get(k,"")).upper()==v),dic

def save_csv(rows,path):
    with path.open("w",newline="",encoding="utf-8-sig") as f:
        writer=csv.DictWriter(f,fieldnames=list(rows[0]),delimiter=";")
        writer.writeheader(); writer.writerows(rows)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--verification-seulement",action="store_true")
    parser.add_argument("--worker",action="store_true")
    parser.add_argument("--model",default="")
    parser.add_argument("--ctx",type=int,default=0)
    parser.add_argument("--prompt",default="")
    parser.add_argument("--output",default="")
    parser.add_argument("--timeout",type=int,default=30)
    parser.add_argument("--repetitions",type=int,default=1)
    args=parser.parse_args()
    if args.worker: sys.exit(worker(args))
    if not 1<=args.repetitions<=3: parser.error("Repetitions entre 1 et 3.")
    prompt,keys,approx,n=build()
    if not (35000<=approx<=49000): raise RuntimeError(f"Dimension incorrecte {approx}")
    print(f"PREFLIGHT: {n} fiches de panels, {approx} tokens estimes avec tiktoken, {len(prompt):,} caracteres",flush=True)
    print(f"5 cles a retrouver, dispersees sur {len(prompt):,} caracteres; controle direct via Ollama sans recherche.",flush=True)
    if args.verification_seulement:
        print("PREFLIGHT OK : modele non sollicite. Mesurer les tokens reels a l'execution.",flush=True)
        return
    ROOT.mkdir(parents=True,exist_ok=True)
    outdir=ROOT/("LongContexteV3-"+time.strftime("%Y%m%d-%H%M%S"))
    outdir.mkdir()
    prompt_path=outdir/"registre-long-contexte.txt"
    prompt_path.write_text(prompt,encoding="utf-8")
    # Le modele n'a acces qu'au texte de sa requete, pas a ce fichier d'attendus.
    (outdir/"attendus-local.json").write_text(json.dumps(keys,indent=2),encoding="utf-8")
    print("RESULTATS :",str(outdir),flush=True)
    print("Benchmark de LONG CONTEXTE DIRECT, distinct du benchmark agentique OpenCode.",flush=True)
    if free_mb()<7000: raise RuntimeError("Pas assez de RAM libre avant chargement (seuil 7 Go).")
    rows=[]
    try:
        for rep in range(args.repetitions):
            order=MODELS if rep%2==0 else list(reversed(MODELS))
            for label,model,ctx in order:
                print(f"\n[{label} essai {rep+1}] Dechargement et prechauffage Ollama {ctx}...",flush=True)
                unload()
                context,vram=warm(model,ctx)
                startmem=free_mb()
                print(f"[{label}] contexte Ollama={context}, VRAM prechauffage={vram} MiB, RAM libre={startmem} MiB",flush=True)
                if startmem<4500:
                    raise RuntimeError(f"[{label}] Protection : RAM libre {startmem} Mo < 4500 Mo apres prechauffage.")
                filename=f"{label}-essai-{rep+1:02d}"
                reply_file=outdir/(filename+"-reponse.json")
                log_file=outdir/(filename+"-worker.log")
                with log_file.open("w",encoding="utf-8") as lf:
                    cmd=[sys.executable,str(Path(__file__).resolve()),"--worker","--model",model,
                         "--ctx",str(ctx),"--prompt",str(prompt_path),"--output",str(reply_file),
                         "--timeout",str(args.timeout)]
                    start=time.monotonic()
                    proc=subprocess.Popen(cmd,stdout=lf,stderr=subprocess.STDOUT)
                    minram=free_mb(); peakvram=gpu_mb(); low=0; reason=""
                    while proc.poll() is None:
                        time.sleep(7)
                        ram=free_mb()
                        mem=gpu_mb()
                        if ram>=0: minram=min(minram,ram)
                        if mem>=0: peakvram=max(peakvram,mem)
                        if ram>=0 and ram<1500: low+=1
                        else: low=0
                        if low>=2:
                            reason="STOP_RAM"; proc.kill(); break
                        if time.monotonic()-start>args.timeout*60:
                            reason="TIMEOUT"; proc.kill(); break
                    try: proc.wait(timeout=15)
                    except Exception: proc.kill()
                    duration=round(time.monotonic()-start,2)
                try: result=json.loads(reply_file.read_text(encoding="utf-8"))
                except Exception: result={"error":f"Pas de reponse ({reason or proc.returncode})"}
                count,values=extract(result,keys)
                prompt_tokens=result.get("prompt_eval_count",-1)
                print(f"[{label}] {duration} s ; prompt_eval_count={prompt_tokens} ; "
                      f"cles correctes={count}/5 ; RAM min={minram} MiB ; VRAM max={peakvram} MiB",flush=True)
                row={"Date":time.strftime("%Y-%m-%dT%H:%M:%S"),
                     "Modele":label,"ContexteDemande":ctx,"ContexteReelOllama":context,
                     "Essai":rep+1,"TokensEstimesTiktoken":approx,"PromptEvalCountOllama":prompt_tokens,
                     "TokensSortie":result.get("eval_count",-1),
                     "BonnesCles":count,"ClesTotales":5,
                     "TempsTotalSecondes":duration,"DureeServeurSecondes":round(result.get("total_duration",0)/1e9,2),
                     "RAMLibreMiniMiB":minram,"VRAMPicMiB":peakvram,
                     "SortieCode":proc.returncode,"Erreur":reason or result.get("error",""),
                     "Reponse":str(reply_file)}
                rows.append(row)
                save_csv(rows,outdir/"resultats.csv")
                if reason=="STOP_RAM":
                    print("STOP RAM : benchmark interrompu pour proteger Windows.",flush=True)
                    return
    finally:
        unload()
    print("\nBENCHMARK TERMINE :",str(outdir/"resultats.csv"),flush=True)
    if len(rows)>=2:
        for row in rows: print(row["Modele"],"tokens charges",row["PromptEvalCountOllama"],"exactitude",str(row["BonnesCles"])+"/5",flush=True)
    print("ATTENTION : les essais comparent la recuperation d'informations dans un contexte direct, PAS l'autonomie agentique d'OpenCode.",flush=True)

if __name__=="__main__":
    main()
