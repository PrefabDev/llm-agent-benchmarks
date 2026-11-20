# Préfa complexe V2 — comparaison MoE 16K / 32K (20 novembre 2026)

## Objet

Deux configurations **du même modèle Qwen3.6 35B-A3B MoE (GGUF Q4)**, utilisées dans **OpenCode et Ollama**, cherchent à corriger une application Python de calcul de préfabrication de **30 fichiers**. Départ : **40 tests visibles, 17 échecs et 1 erreur**. Après l'agent, **21 tests de validation indépendants** sont exécutés, sans être accessibles à l'agent durant sa correction.

Matériel : **RTX 4060 Ti 16 Go**, Ryzen 9 9950X3D, 32 Go de RAM, Windows/PowerShell. L'exécution des deux configurations a eu lieu **dans l'ordre 16K puis 32K**, une seule fois chacune.

## Résultats bruts

| Mesure | MoE 16K | MoE 32K |
|---|---:|---:|
| Contexte configuré Ollama | 16 384 | 32 768 |
| Temps de résolution (s) | 986,56 | **613,84** |
| Temps de résolution | 16 min 27 s | **10 min 14 s** |
| Tests visibles après premier passage | **40/40** | 22/40 |
| Nombre de passages OpenCode | **1** | 2 |
| Relances automatiques | **0** | 1 |
| Tests visibles finaux | **40/40** | **40/40** |
| Tests de validation indépendants | **21/21** | **21/21** |
| Fichiers de tests / README préservés | Oui | Oui |
| Tokens rapportés, maximum du champ `total` | 16 384 | 28 972 |
| Tokens de sortie rapportés (agrégés) | 35 136 | 20 319 |
| Appels d'outils rapportés | 83 | 58 |
| Étapes rapportées | 31 | 29 |
| Pic VRAM échantillonné (MiB) | 15 946 | 15 941 |
| Minimum RAM libre échantillonné (Mo) | 3 845 | 3 926 |
| Durée de préchauffage (exclue du chrono) | 15,08 s | 15,65 s |

**Sur cet essai, le 32K a achevé le travail 372,72 secondes plus tôt (6 min 13 s), soit un gain de temps d'environ 37,8 % (rapport 1,61×).** En revanche, il a fallu **une relance automatique**, alors que le 16K a réussi dès son premier passage.

Le 32K utilise moins de tokens de sortie rapportés et moins d'appels d'outils, **mais ces indicateurs ne suffisent pas à expliquer causalement l'écart de durée**.

## Interprétation et limites

- Les deux modèles ont satisfait **61 tests sur 61** en fin d'exécution, y compris les 21 tests indépendants.
- Le **16K atteint 16 384** dans le champ `MaxTokensRapportes`, et le 32K atteint **28 972**. Ce champ correspond au **maximum du champ `total` des événements OpenCode** : ce **n'est ni une mesure directe d'occupation du contexte ni une preuve de saturation / compaction**.
- La VRAM maximale échantillonnée est voisine pour les deux essais : cela **ne prouve pas** une équivalence de consommation réelle ou une absence de pics entre les échantillons.
- Les deux réalisations ont commencé avec des copies neuves de l'application. Le script chronomètre les passages OpenCode et les contrôles entre passages ; **le préchauffage du modèle et l'extraction de la copie ne sont pas inclus**.
- **Un seul essai par configuration**, toujours dans le même ordre : impossible de conclure à une accélération moyenne reproductible. L'aléa des agents (décisions de correction, navigation, relances) intervient autant que l'inférence.
- Il faut **répéter en alternant l'ordre**, puis étudier les logs d'événements (outils, compactions, temps par passage, nature des corrections).

## Sources

- [Résultats CSV originaux](../data/2026-11-20-prefa-complex-v2-moe-16k-vs-32k.csv)
- [Script de comparaison 16K / 32K, première version](../scripts/Benchmark-MoE-16K-vs-32K.ps1) — **ce script correspond à l'ancien benchmark simple**, pas à la V2 complexe. Le script V2 complexe et son kit doivent encore être ajoutés au dépôt avant de déclarer l'expérience entièrement reproductible.
