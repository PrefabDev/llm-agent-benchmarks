# Benchmark V4 — Essai de fenêtre 128K contre 64K

**Date : 20 novembre 2026 · Statut : INCOMPLET, arrêté par sécurité mémoire**

Ce protocole teste les alias Ollama du **même modèle Qwen3.6 35B-A3B MoE Q4**, avec des contextes configurés à 65 536 et 131 072 tokens. Il ne s'agit **pas** d'un benchmark de programmation OpenCode : le modèle doit retrouver cinq clés dans un long registre fictif de préfabrication en une seule requête directe à Ollama.

## Jeu d'essai

- **679 fiches techniques synthétiques**, environ **261 254 caractères**.
- **85 085 tokens estimés avec tiktoken cl100k_base** ; le nombre de tokens réellement traités n'est connu qu'après une inférence complète.
- Cinq clés de référence à restituer, réparties dans le registre. Aucune information privée n'a été utilisée.
- Configuration matérielle : Ryzen 9 9950X3D, RTX 4060 Ti **16 Go**, **32 Go de RAM**.
- [Script Python pour reproduire le test](../scripts/Benchmark-LongContexte-64K-vs-128K.py). L'alias `qwen36-moe:128k` est créé à partir de `qwen36-moe:64k`, sans téléchargement des poids.

## Ce qui a été mesuré

| Critère | MoE 64K | MoE 128K |
|---|---:|---:|
| Contexte Ollama confirmé au préchauffage | 65 536 | **131 072** |
| RAM libre après préchauffage | 6 793 Mio | **5 665 Mio** |
| Inférence du long registre | Exécutée | **Non exécutée** |
| `prompt_eval_count` relevé | 32 770 | Non disponible |
| Clés correctement restituées | 2/5 | Non mesuré |
| Temps total | 56,41 s | Non mesuré |
| RAM libre minimale pendant l'exécution | 6 193 Mio | Non mesurée |
| Pic VRAM échantillonné | 15 908 Mio | Non mesuré |

**Pourquoi l'arrêt ?** Le script interrompt volontairement la préparation 128K lorsque la RAM libre est inférieure à **7 000 Mio** après préchauffage. À l'instant du test, seulement **5 665 Mio** étaient disponibles. Le script s'est arrêté avec un message d'erreur *préventif*, sans exécuter le prompt 128K.

**Aucune comparaison de qualité 64K / 128K n'est donc possible à ce stade.** Le fait que l'alias 128K se charge ne prouve pas qu'une requête de plus de 64K serait traitée correctement, ni que l'expérience serait stable sous charge. Pour compléter : libérer de la RAM, conserver les protections, répéter en alternant les modèles et mesurer `prompt_eval_count` et l'exactitude.

## Artefacts

- [CSV original de l'essai 64K (seul résultat complet)](../data/2026-11-20-long-context-v4-64k-run-128k-aborted.csv).
- [Script V4](../scripts/Benchmark-LongContexte-64K-vs-128K.py).

**Ce benchmark n'a pas été publié comme « succès du 128K » : aucune inférence 128K n'a été exécutée.**
