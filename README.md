# Linky Monitor

Application macOS native pour consulter l’historique de consommation quotidienne d’un compteur Linky.

## Fonctions

- Connexion à Conso API avec un token conservé dans le Trousseau macOS.
- Saisie locale du PRM/PDL.
- Consultation et comparaison de périodes de consommation, avec estimation des coûts.
- Interface macOS en français et page de diagnostics accessible avec **Maj + clic sur Réglages/Préférences**.

Les données affichées sont des relevés quotidiens fournis par le service utilisé ; l’application ne donne pas de mesure en temps réel.

## Démarrer

1. Ouvrir `Linky Monitor.xcodeproj` dans Xcode.
2. Sélectionner la cible **LinkyMonitor** et lancer l’application sur un Mac.
3. Dans **Connexion**, saisir le PRM/PDL et le token obtenu via le parcours de consentement Conso API/Enedis.

Le token est stocké dans le Trousseau macOS. Le PRM/PDL est enregistré localement dans les préférences de l’application. Ces valeurs ne sont pas nécessaires pour compiler le projet et ne doivent pas être ajoutées au dépôt.

## Service de données

L’application interroge [Conso API](https://conso.boris.sh/) pour récupérer les consommations quotidiennes. Conso API est un service tiers ; ce projet n’est ni publié ni approuvé par Enedis. Consultez sa [documentation](https://conso.boris.sh/documentation/) et ses conditions avant utilisation.

## Confidentialité

Ne publiez jamais votre token, votre PRM/PDL, des journaux contenant ces données, ni les fichiers de configuration personnels de Xcode. Le dépôt ne doit contenir que le code et les fichiers du projet.

## Licence

Aucune licence open source n’est définie pour le moment. Sans licence, les visiteurs peuvent consulter le dépôt, mais ne disposent pas d’une autorisation générale pour réutiliser ou redistribuer le code.
