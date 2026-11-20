# LLM Agent Benchmarks

Benchmarks **locaux, orientés tâche**, pour comparer des modèles de code utilisés comme **agents autonomes** avec **Ollama + OpenCode**. Les mesures portent sur une résolution effective de problèmes (modification de fichiers et exécution des tests), pas seulement sur les tokens/s.

> **État : essais exploratoires, non scientifiques.** Peu de répétitions, variabilité importante, protocoles v1.1, v1.2 et v1.3 différents. Ne pas fusionner leurs temps pour établir un score global.

## Matériel et environnement

- **GPU** : NVIDIA GeForce RTX 4060 Ti **16 Go**.
- **CPU** : AMD Ryzen 9 9950X3D.
- **RAM** : 32 Go.
- **Système** : Windows, PowerShell 5.1.
- **Moteurs** : Ollama + OpenCode 1.19.5.
- **Modèles** : `qwen3-opencode` (Qwen3 14B, variante locale) et `qwen36-moe:16k` / `qwen36-moe:32k` (Qwen3.6 35B-A3B MoE, GGUF Q4).
- **Contexte** : comparaisons 14B / MoE 16K à **16 384 tokens** ; premier essai MoE **16 384 vs 32 768 tokens** publié ci-dessous.

## Tâche métier de test

Une application Python fictive de **calcul de panneaux en béton préfabriqué**, répartie entre `geometry.py`, `mass.py`, `checks.py` et `report.py`.

Départ : **15 tests unitaires, 8 réussites et 7 échecs**, provoqués par quatre anomalies : volume net des réservations, densité d'isolant, coefficient de sécurité au levage et conversion kilogrammes/tonnes.

**Consigne :** identifier les erreurs, corriger les modules métier, lancer les tests, **ne pas modifier les tests**. Chaque essai reprend une copie initiale identique.

## Résultats mesurés

### Nouveau — Projet complexe V2 : MoE 16K contre 32K (20 novembre 2026)

Deux essais sur une application Python de **30 fichiers**, avec **40 tests visibles** et **21 tests indépendants** :

| MoE | Temps agent | Premier passage | Fin | Relances | Max. tokens rapportés |
|---|---:|---:|---:|---:|---:|
| 16K | 986,56 s | **40/40** | **61/61** | 0 | 16 384 |
| 32K | **613,84 s** | 22/40 | **61/61** | 1 | 28 972 |

**32K a terminé 37,8 % plus vite sur ce seul essai**, mais 16K a travaillé sans relance. **Ce n'est pas une conclusion statistique** sur la supériorité de l'une ou l'autre fenêtre.

Lire le [rapport V2 détaillé](reports/2026-11-20-prefa-complex-v2-16k-vs-32k.md) et le [CSV d'origine](data/2026-11-20-prefa-complex-v2-moe-16k-vs-32k.csv).

### Série initiale automatisée — 19 novembre 2026, protocole v1.1

| Modèle | Temps agent | Tests finaux | Statut |
|---|---:|---:|---|
| Qwen3 14B | 284,78 s | 10/15 | Échec |
| Qwen3.6 35B MoE 16K | 252,86 s | 15/15 | Réussite fonctionnelle |

Le contrôleur v1.1 signalait à tort les sources de tests comme modifiées : les fichiers `__pycache__` créés par Python étaient comptés. **Un audit ultérieur a confirmé que les sources des tests étaient intactes pour ces deux essais.**

Source : [CSV brut v1.1](data/2026-11-19-v1.1.csv).

### Série de trois essais — 20 novembre 2026, protocole v1.2

| Essai | Qwen3 14B | Qwen3.6 35B MoE 16K |
|---|---|---|
| 1 | 41,74 s — 8/15 | 93,38 s — 8/15 |
| 2 | 132,83 s — 8/15 | 95,39 s — 8/15 |
| 3 | 172,58 s — 8/15 | 625,26 s — 15/15 |

**Réussite : 0/3 pour le 14B et 1/3 pour le MoE.** Ces essais n'avaient pas encore la logique de relance v1.3. Résultats repris de la console du benchmark ; CSV v1.2 non inclus ici.

### V1.3 — 20 novembre 2026, premier passage vs relances

| Campagne | Modèle | Temps total | Premier passage | Final | Relances | Résultat |
|---|---|---:|---:|---:|---:|---|
| Matin, GPU à fréquence verrouillée | 14B | 1 200,43 s | Non terminé | 12/15 | 0 | Timeout |
| Matin, GPU à fréquence verrouillée | MoE 16K | **143,01 s** | **15/15** | **15/15** | **0** | Succès |
| Soir, après redémarrage, fréquence automatique présumée | 14B | 827,19 s | 8/15 | 15/15 | 2 | Succès assisté |
| Soir, après redémarrage, fréquence automatique présumée | MoE 16K | **147,36 s** | **15/15** | **15/15** | **0** | Succès autonome |

Le **facteur 5,61×** (827,19 / 147,36) concerne **uniquement l'essai v1.3 du soir** : le 14B a nécessité **deux relances** et le MoE aucune. Ce **n'est ni une moyenne ni une accélération garantie**. Le GPU n'a pas fait l'objet d'un relevé continu de fréquence certifiant le mode automatique.

Sources : [CSV v1.3 matin](data/2026-11-20-v1.3-matin.csv) · [CSV v1.3 soir](data/2026-11-20-v1.3-soir.csv).

### MoE 16K contre 32K — 20 novembre 2026 (premier essai)

Même modèle MoE Q4 et même application Python, avec le protocole automatisé à relances bornées. Les deux contextes demandés ont été confirmés par Ollama lors du préchauffage.

| Critère | MoE 16K | MoE 32K |
|---|---:|---:|
| Contexte Ollama configuré | 16 384 | **32 768** |
| Temps agent (hors préchauffage) | 219,10 s | **185,66 s** |
| Tests au premier passage | **15/15** | 8/15 |
| Tests finaux | **15/15** | **15/15** |
| Relances automatiques | **0** | 1 |
| Préchauffage | 14,34 s | 14,28 s |
| VRAM rapportée par Ollama au chargement | 13 501 Mo | 13 373 Mo |
| RAM libre au préchauffage | 10 374 Mo | 11 683 Mo |
| Fréquence GPU instantanée pré-test | 2 595 MHz | 2 595 MHz |

**Observations** : dans cet essai, le 32K a pris **33,44 s de moins** (environ **15,3 %**) mais **n'a pas réussi au premier passage**. Le 16K a réussi immédiatement. L'usage de la fenêtre complète de 32K **n'est pas démontré** par la seule valeur configurée. Les relevés de VRAM, RAM et GPU sont des instantanés et ne mesurent ni les pics ni les moyennes pendant l'inférence. **Un seul essai, dans l'ordre 16K puis 32K, ne suffit pas à conclure** que le 32K est plus rapide ou moins gourmand.

Source : [CSV brut du 20 novembre — MoE 16K vs 32K](data/2026-11-20-moe-16k-vs-32k.csv).

## Méthode de mesure

1. Extraction d'une **copie neuve** pour chaque essai.
2. **Préchauffage** Ollama, exclu du chronométrage de l'agent.
3. Lancement `opencode run` avec une consigne commune, outils activés.
4. Durée `System.Diagnostics.Stopwatch` : temps OpenCode et, en v1.3, éventuelles relances et contrôles entre passages.
5. Vérification indépendante : `python -m unittest discover -s tests -v`.
6. Vérification SHA-256 des fichiers de tests et du README (en excluant les caches Python).
7. Sauvegarde des CSV et journaux ; relevés GPU **instantanés**, **pas** des moyennes d'utilisation ou de consommation.

Le mécanisme de relance v1.3 a changé la définition de « réussite » : distinguer **succès au premier passage** et **succès après intervention automatique**.

## Scripts

- [Projet Python initial, avec les sept échecs](benchmark/prefa-panel/README.md) : codes sources et tests de référence.
- [Générer l'archive ZIP compatible](scripts/Creer-Archive-Benchmark.ps1) : reconstruit l'archive identique pour les deux candidats à partir des sources publiées.
- [Benchmark OpenCode v1.3](scripts/Benchmark-OpenCode-LLM-v1.3.ps1) : comparaison 14B / MoE 16K, relances bornées.
- [Benchmark MoE 16K vs 32K](scripts/Benchmark-MoE-16K-vs-32K.ps1) : script expérimental ; premier essai chronométré publié.
- [Ajout de l'alias 32K à OpenCode](scripts/Ajouter-MoE32K-OpenCode.ps1).

**Pré-requis** : Windows / PowerShell 5.1, Python 3, Ollama, OpenCode, modèles déjà installés, archive de projet `Benchmark_PREFA_14B_vs_MoE.zip` dans `D:\IA\Tests`. Depuis la racine du dépôt, lancer d'abord `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Creer-Archive-Benchmark.ps1` pour préparer l'archive. Puis adapter les chemins et paramètres des scripts aux installations locales. **Relire les scripts avant exécution**.

> ⚠️ `--auto` / `-AutoApprove` : l'agent peut exécuter des commandes et modifier des fichiers. **Un dossier de benchmark n'est pas un bac à sable de sécurité.** Exécuter uniquement sur une machine de confiance, avec des données non sensibles et idéalement dans une VM isolée.

## Limites et prochaines expériences

- Déterminisme imparfait des agents : un même prompt peut mener à une réponse sans modification du code.
- Comparaisons sensibles au mode interactif/non interactif, à la compaction, à la charge CPU/GPU et aux paramètres mémoire.
- Un seul essai 16K / 32K : fenêtre configurée confirmée, mais contexte réellement consommé non mesuré ; répéter en alternant l'ordre.
- À faire : essais supplémentaires, chronométrage robuste, relevés continus RAM/VRAM, tâches inédites avec tests cachés.

**Licence :** aucune licence de réutilisation n'est encore accordée ; choix à définir avant diffusion des scripts comme projet open source.
