# Benchmark V3 — véritable long contexte 32K contre 64K
**20 novembre 2026 · Qwen3.6 35B-A3B MoE Q4 · Ollama local**

## Question

Le modèle réglé en **64K** retrouve-t-il des informations placées dans un dossier d'une **taille effective supérieure à 32 768 tokens**, alors que le réglage **32K** ne peut pas tout conserver en contexte ?

**Attention : épreuve de récupération de faits en entrée directe d'Ollama, pas un benchmark de l'agent OpenCode.** Le but est d'isoler le bénéfice de capacité mémoire contextuelle sans outils de recherche.

## Protocole reproductible

- Même GPU **RTX 4060 Ti 16 Go**, CPU Ryzen 9 9950X3D et 32 Go de RAM.
- Même GGUF Q4, alias Ollama `qwen36-moe:32k` (`num_ctx=32768`) et `qwen36-moe:64k` (`num_ctx=65536`).
- Dossier synthétique de préfabrication : **350 fiches** de panneaux, **134 970 caractères**, **43 911 tokens estimés avec tiktoken cl100k_base**. Les comptes réels du modèle viennent d'Ollama.
- Le modèle doit restituer les **cinq clés uniques** de fiches réparties à l'entrée, au début, au milieu et en fin de registre : `REF-00006`, `REF-00035`, `REF-00140`, `REF-00245`, `REF-00340`.
- La requête est fournie **en une seule fois**, sans accès aux réponses attendues, à un terminal ni aux fichiers source. `temperature=0`, `seed=42`, `num_predict=320`, `think=false`, `format=json`.
- Trois exécutions par configuration : une paire initiale, puis deux nouvelles paires, dont une dans l'ordre inverse.
- Chaque résultat est comparé aux cinq clés attendues ; les durées et échantillons de mémoire sont enregistrés.

Le script est public et génère lui-même le jeu de données, sans fichier confidentiel : [Benchmark Python V3](../scripts/Benchmark-LongContexte-32K-vs-64K.py).

## Résultats

| Essai | Configuration | Tokens évalués rapportés par Ollama (`prompt_eval_count`) | Clés exactes | Durée |
|---|---|---:|---:|---:|
| 1 | 32K | 16 386 | **2/5** | 28,20 s |
| 1 | 64K | **48 920** | **5/5** | 84,59 s |
| 2 | 32K | 16 386 | **2/5** | 28,19 s |
| 2 | 64K | **48 920** | **5/5** | 77,58 s |
| 3, ordre inversé | 64K | **48 920** | **5/5** | 84,55 s |
| 3, ordre inversé | 32K | 16 386 | **2/5** | 28,20 s |

### Moyennes (sur trois exécutions chacune)

- **32K : 2/5 clés, 28,20 secondes**.
- **64K : 5/5 clés, 82,24 secondes**.
- Le 64K est **environ 2,9 fois plus lent**, mais il est **100 % exact sur les cinq faits**, contre 40 % en 32K.
- Dans les trois essais, le 32K restitue les **deux clés situées en fin de corpus**, pas les trois premières, ce qui est cohérent avec une troncature des informations initiales.

**Mesure de contexte :** la valeur `prompt_eval_count=48 920` dans Ollama au 64K établit qu'une requête d'environ **49K tokens** a effectivement été évaluée. En 32K, l'API rapporte **16 386 tokens évalués** pour la **même requête envoyée**. Cette métrique n'est pas la longueur totale soumise au serveur ni une mesure détaillée de l'occupation de la fenêtre ; le mécanisme exact de sélection/troncature est propre au backend. Il ne faut pas assimiler `prompt_eval_count` à la capacité nominale entière d'un modèle.

### Ressources

- RAM libre minimale : **6 698 à 7 086 Mio** lors des essais 64K, contre **7 421 à 7 736 Mio** pour les 32K.
- Pic VRAM échantillonné : **15 725 à 15 878 Mio** pour le 64K ; jusqu'à **15 889 Mio** pour le 32K.
- Contrôles : refus si RAM après chargement <4 500 Mio, interruption du processus client si <1 500 Mio sur deux échantillons, limite de 30 minutes par requête. **Ce ne sont pas des garanties absolues contre une saturation mémoire côté serveur.**

## Interprétation

**L'avantage du 64K est réel et reproductible sur ce test ciblé :** il peut récupérer des faits situés dans une requête de ~49K tokens que le réglage 32K ne restitue pas entièrement. **L'avantage n'est pas la vitesse** : ici, le prix payé pour conserver davantage de contexte est important.

Ce protocole est délibérément un « long-document / retrieval » avec des valeurs synthétiques. Il ne mesure **ni le raisonnement sur un véritable code source, ni la vitesse d'un agent OpenCode, ni la qualité de correction du béton préfabriqué en production**. Un agent de code peut chercher, relire ou résumer ses fichiers au lieu de les maintenir simultanément en contexte. Trois répétitions du même texte avec la même graine ne représentent pas une diversité statistique de problèmes.

## Sources CSV originales

- [Première paire](../data/2026-11-20-long-context-v3-initial.csv)
- [Deux autres paires, ordre alterné](../data/2026-11-20-long-context-v3-replicates.csv)
