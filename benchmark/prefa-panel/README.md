# Benchmark local de programmation - Panneaux préfabriqués

Petit projet Python utilisant uniquement la bibliothèque standard. Ce dossier est une copie indépendante réservée au modèle testé.

## Spécification fonctionnelle

- Dimensions et épaisseurs exprimées en mètres ; volumes en m³, masses en kg ou tonnes.
- Les réservations traversantes retirent une surface à toutes les couches du panneau.
- Le volume net du panneau correspond à la surface nette multipliée par son épaisseur.
- La masse d'un panneau sandwich est la somme des masses de sa peau extérieure, de sa peau intérieure et de son isolant, chacun avec **sa propre densité**. Les réservations traversantes diminuent les trois masses.
- Un moyen de levage est acceptable si sa capacité est **supérieure ou égale à la masse multipliée par le coefficient de sécurité** ; à l'égalité, c'est acceptable.
- Une tonne vaut **1 000 kg**. Les rapports conservent des nombres non arrondis pour les calculs.
- Les dimensions de panneaux et réservations doivent être positives. Le coefficient de sécurité doit être au moins égal à 1.

## Objectif de l'agent

Analyser le projet, comprendre pourquoi certains tests échouent, corriger les seuls modules nécessaires dans `prefa/`, exécuter les tests et rendre compte des changements.

### Contraintes de l'évaluation

- Ne modifier **ni les tests**, ni ce README, ni la structure des dossiers.
- Ne pas créer de dépendance externe, ne pas télécharger de paquet.
- Ne pas contourner ni neutraliser les assertions ; corriger les calculs.
- Ne rien modifier en dehors de ce répertoire.

### Lancer les tests

Depuis la racine de ce dossier :

```powershell
python -m unittest discover -s tests -v
```
