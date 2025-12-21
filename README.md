
Etape 0 : Détermination de l’emprise du territoire d’identification du gisement
Etape 1 : Création du masque bâtiment
Adaptation du masque selon la taille du bati (2m <50m² sinon 50m)
Etape 2 : Création du masque des infrastructures linéaires (route, rail)
Adaptation du masque selon l’importance de l’infra linéaire (15m pour voirie principal et rail, 7m voirie secondaire)
Etape 3 : Création du masque des équipements et des spécificités du territoire
Etape 4 : Identification des parcelles candidates
Etape 5 : Identification du gisement non bâti
Etape 6 - optionnelle : Identification du gisement bâti
Répétition des étapes 4 & 5 spécifiques à la définition du gisement bâti.
Etape 7 : Mise en forme de la couche finale


A faire : 
- Découper les buffer par communes de l'EPCI
- Améliorer le script pour pas que l'on voit les parties IA
- Faire une fusion des géométries pour la couche des parcelles candidates ??
- Erreur à la fin du script : une des géométries n'est pas contenu dans l'epci

Calculs à réaliser :
- Calculer la tâche urbaine pour les deux communes de l'EPCI dont nous ne disposons pas d'informations (pour l'étape optionnelle)

PROF MAIL CONTENT
Elements complémentaires apportés:

Le résultat attendu est un script permettant de calculer les gisements sur TOUTES les communes de la CAPI.

Vous n’avez pas le zonage d’urbanisme sur 2 communes. Donc vous ne pouvez pas identifier les gisements sur ces communes. Pour palier ce manque de donnée l’idée est de créer une donnée qui s’en approche. La tache urbaine répond donc à ce besoin pour les 2 communes en question. Vous allez chercher les gisements au sein de la tache urbaine en remplacement du PLU sur ces 2 communes.

La tache urbaine correspond aux espaces anthropiques. On part du principe que les espaces anthropiques sont déjà dans des zones U et AU.

Selon les débats de spécialistes, le réseau routier appartient ou non à la tache urbaine. Moi je vous demande d’inclure le réseau routier dans la tâche.

Vous devez donc créer une tache urbaine à partir des données mises à disposition. Avec les données fournies, vous avez 2 solutions :

    Créer une tache à partir d’éléments anthropiques fournis à jeu de sélection d’objets et de buffer pour obtenir des zones au sein desquelles calculer les gisements.
    Créer une tache urbaine à partir de l’occupation du sol (sélection et reclassification de l’occ sol). Vigilance sur les zones retenues pour composer la tâche.

J’avais donné ces détails oralement.

Il n’est pas demandé de faire apparaitre les parcelles dans la tache urbaine. Aucun intérêt vous allez ralentir vos traitements. Il vous faut une enveloppe de polygones au sein de laquelle rechercher les gisements. Votre tâche urbaine doit être calculée et intégrée dans le script afin que vous puissiez identifier les gisements.  La manière dont vous allez insérer cette « brique » de calcul sera regardée.

Je ne dis pas comment intégrer la tache urbaine, ça fait partie de l’exercice. C’est de la logique.

Solution 1 : 
Topo urbain = 50m premier buffer puis -30m 
méthode du SCOT
